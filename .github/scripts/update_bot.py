#!/usr/bin/env python3
"""Nightly update bot: one PR per day, quarantine of breaking updates, escalation to Claude.

Subcommands: see --help; the flow is in docs/updates.md.

A "unit" is one revertible update: a root flake input (by name) or a package
with an updater (`pkgs/<name>`). State lives in the pinned `update-status` issue.

Environment: BOT_TOKEN (PAT; pushes and PRs, so CI runs) and GITHUB_TOKEN
(issues and comments, so the owner is notified), GITHUB_REPOSITORY.
"""

import argparse
import base64
import copy
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from update_packages import UPDATERS  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
BRANCH = "auto/update"
FIX_PREFIX = "auto/fix-"
STATE_LABEL = "update-status"
HELD_LABEL = "update-held"
VERDICT_LABELS = ["fix-pr", "upstream", "needs-human"]
# Nights in a row a unit may be held back before an issue is opened.
THRESHOLDS = {"build": 3, "eval": 3, "script": 3, "fetch": 7, "timeout": 7, "cache": 7}
# Failures before CI (an updater, a fetch or the cache gate); tracked by `nightly`, not by `landed`.
UPDATE_KINDS = {"script", "fetch", "cache"}
# Missing caches and unreachable upstreams aren't fixable in code, so no fix agent.
UNFIXABLE_KINDS = {"timeout", "fetch", "cache"}
# Input -> (attr, cache): the input only advances once the cache can serve attr, so CI never compiles it.
CACHE_GATED = {
    "nixpkgs-cuda": ("packages.x86_64-linux.llama-cpp-cuda", "https://cache.nixos-cuda.org"),
}
MAX_TRIAGE_PASSES = 3
META_RE = re.compile(r"<!-- update-bot\n(.*?)\n-->", re.S)

# Not flake.nix/flake.lock: CI runs binaries from the locked inputs, with secrets, before any review.
FIX_ALLOWED = ("modules/", "pkgs/", "hosts/", "lib/")
FIX_MAX_FILES = 3
FIX_MAX_LINES = 40
FIX_FORBIDDEN_ADDED = [
    r"enable\s*=\s*false",
    r"allowBroken",
    r"allowInsecure",
    r"permittedInsecurePackages",
    r"allowUnsupportedSystem",
]
FIX_FORBIDDEN_REMOVED = [r"fireproof\.", r"enable\s*=\s*true"]


# --- shell helpers ---------------------------------------------------------


def run(*cmd: str, cwd: Path = ROOT, check: bool = True, env: dict | None = None) -> str:
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env={**os.environ, **(env or {})})
    if check and p.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} failed ({p.returncode}):\n{p.stderr}")
    return p.stdout


def gh(*args: str, bot: bool = False, check: bool = True) -> str:
    """Run gh as github-actions (default; notifies the owner) or the owner's PAT (bot=True; triggers CI)."""
    token = os.environ.get("BOT_TOKEN" if bot else "GITHUB_TOKEN") or os.environ["GITHUB_TOKEN"]
    return run("gh", *args, env={"GH_TOKEN": token}, check=check)


def gh_json(*args: str, bot: bool = False):
    return json.loads(gh(*args, bot=bot) or "null")


def today() -> str:
    return datetime.datetime.now(datetime.UTC).date().isoformat()


def owner() -> str:
    return os.environ["GITHUB_REPOSITORY"].split("/")[0]


def set_output(**kv) -> None:
    if path := os.environ.get("GITHUB_OUTPUT"):
        with open(path, "a") as f:
            for k, v in kv.items():
                f.write(f"{k}={v}\n")


def embed(meta: dict) -> str:
    return f"<!-- update-bot\n{json.dumps(meta, indent=1, sort_keys=True)}\n-->"


def extract(body: str) -> dict:
    m = META_RE.search(body or "")
    return json.loads(m.group(1)) if m else {}


def ensure_labels() -> None:
    for name, color in [
        (STATE_LABEL, "0e8a16"),
        (HELD_LABEL, "d93f0b"),
        ("auto-fix", "5319e7"),
        ("needs-review", "b60205"),
        *[(v, "c5def5") for v in VERDICT_LABELS],
    ]:
        gh("label", "create", name, "--color", color, "--force")


# --- flake.lock surgery ----------------------------------------------------


def read_lock(ref: str | None, tree: Path = ROOT) -> dict:
    text = (
        (tree / "flake.lock").read_text()
        if ref is None
        else run("git", "show", f"{ref}:flake.lock", cwd=tree)
    )
    return json.loads(text)


def write_lock(lock: dict, tree: Path) -> None:
    (tree / "flake.lock").write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")


def root_inputs(lock: dict) -> dict:
    return lock["nodes"][lock["root"]]["inputs"]


def gc_lock(lock: dict) -> dict:
    seen, todo = set(), [lock["root"]]
    while todo:
        key = todo.pop()
        if key in seen:
            continue
        seen.add(key)
        todo += [v for v in lock["nodes"][key].get("inputs", {}).values() if isinstance(v, str)]
    lock["nodes"] = {k: v for k, v in lock["nodes"].items() if k in seen}
    return lock


def graft_input(cand: dict, base: dict, name: str) -> dict:
    """Return `cand` with root input `name` and its whole subtree taken from `base`."""
    cand = copy.deepcopy(cand)
    ref = root_inputs(base)[name]
    if isinstance(ref, list):  # a root-level follows
        root_inputs(cand)[name] = ref
        return gc_lock(cand)
    mapping: dict[str, str] = {}

    def copy_node(key: str) -> str:
        if key in mapping:
            return mapping[key]
        new, i = key, 0
        while new in cand["nodes"]:
            i += 1
            new = f"{key}_held{i}"
        mapping[key] = new
        node = copy.deepcopy(base["nodes"][key])
        cand["nodes"][new] = node
        for k, v in node.get("inputs", {}).items():
            if isinstance(v, str):
                node["inputs"][k] = copy_node(v)
        return new

    root_inputs(cand)[name] = copy_node(ref)
    return gc_lock(cand)


def describe_locked(node: dict) -> str:
    locked = node.get("locked", {})
    rev = locked.get("rev", locked.get("narHash", "?"))[:7]
    when = locked.get("lastModified")
    date = datetime.datetime.fromtimestamp(when, datetime.UTC).date().isoformat() if when else "?"
    return f"{rev} ({date})"


# --- units -----------------------------------------------------------------


def package_unit(name: str) -> str:
    return f"pkgs/{name}"


def is_package(unit: str) -> bool:
    return unit.startswith("pkgs/")


def changed_units(base_ref: str, tree: Path = ROOT, package_versions: dict | None = None) -> dict:
    """Map each unit that differs between `base_ref` and the working tree to {"old", "new"}."""
    base, cand = read_lock(base_ref, tree), read_lock(None, tree)
    units = {}
    for name, ref in root_inputs(cand).items():
        bref = root_inputs(base).get(name)
        if not isinstance(ref, str) or not isinstance(bref, str):
            continue
        bnode, cnode = base["nodes"][bref], cand["nodes"][ref]
        if cnode.get("locked", {}).get("type") == "path":
            continue
        if bnode.get("locked") != cnode.get("locked"):
            units[name] = {"old": describe_locked(bnode), "new": describe_locked(cnode)}
    for name in UPDATERS:
        if run("git", "diff", "--name-only", base_ref, "--", package_unit(name), cwd=tree).strip():
            v = (package_versions or {}).get(name, {})
            units[package_unit(name)] = {"old": v.get("old", "?"), "new": v.get("new", "?")}
    return units


def revert_units(tree: Path, units: list[str], base_ref: str) -> None:
    base, cand = read_lock(base_ref, tree), read_lock(None, tree)
    for unit in units:
        if is_package(unit):
            run("git", "checkout", base_ref, "--", unit, cwd=tree)
        else:
            cand = graft_input(cand, base, unit)
    write_lock(cand, tree)


# --- state (pinned status issue) ---------------------------------------------


def load_state() -> tuple[int | None, dict]:
    issues = gh_json("issue", "list", "--label", STATE_LABEL, "--state", "open", "--json", "number,body")
    if not issues:
        return None, {"units": {}}
    return issues[0]["number"], extract(issues[0]["body"]) or {"units": {}}


def render_state(state: dict) -> str:
    repo = os.environ["GITHUB_REPOSITORY"]
    lines = [
        "Maintained by the update bot (`.github/scripts/update_bot.py`); edits are overwritten.",
        "",
        f"Last run: {today()} · [update workflow](https://github.com/{repo}/actions/workflows/update.yml)",
        "",
    ]
    if state["units"]:
        lines += ["| Unit | Reason | Held since | Nights | Issue |", "| --- | --- | --- | --- | --- |"]
        for unit, e in sorted(state["units"].items()):
            issue = f"#{e['issue']}" if e.get("issue") else ""
            nights = f"{len(e['nights'])}/{THRESHOLDS[e['kind']]}"
            lines.append(
                f"| `{unit}` | {e['kind']}: {e.get('summary', '')} | {e['nights'][0]} | {nights} | {issue} |"
            )
    else:
        lines.append("Nothing is held back. 🎉")
    return "\n".join(lines) + "\n\n" + embed(state)


def save_state(number: int | None, state: dict) -> None:
    body = render_state(state)
    if number:
        gh("issue", "edit", str(number), "--body", body)
        return
    url = gh("issue", "create", "--title", "Update status", "--label", STATE_LABEL, "--body", body).strip()
    node = gh_json("issue", "view", url, "--json", "id")["id"]
    gh(
        "api",
        "graphql",
        "-f",
        "query=mutation($id:ID!){pinIssue(input:{issueId:$id}){issue{number}}}",
        "-f",
        f"id={node}",
        check=False,
    )


def hold(state: dict, unit: str, kind: str, summary: str, signature: str) -> dict:
    e = state["units"].setdefault(unit, {"nights": []})
    if today() not in e["nights"]:
        e["nights"].append(today())
    e.update(kind=kind, summary=summary, signature=signature)
    return e


def clear(state: dict, unit: str, note: str) -> None:
    e = state["units"].pop(unit, None)
    if e and e.get("issue"):
        gh("issue", "comment", str(e["issue"]), "--body", note)
        gh("issue", "close", str(e["issue"]))


def escalate(state: dict, unit: str, details: str) -> None:
    """Open the unit's issue once its streak reaches the threshold, and dispatch the fix agent when fixable."""
    e = state["units"][unit]
    if len(e["nights"]) < THRESHOLDS[e["kind"]]:
        return
    fixable = e["kind"] not in UNFIXABLE_KINDS
    if not e.get("issue"):
        ping = "" if fixable else f"\n\n@{owner()} this needs a human; the fix agent can't help here."
        body = (
            f"`{unit}` has been held back from the nightly update for {len(e['nights'])} nights "
            f"(since {e['nights'][0]}).\n\n**Reason:** {e['kind']}: {e['summary']}\n\n{details}{ping}\n\n"
            "This issue closes itself when the update lands."
        )
        labels = [HELD_LABEL, "auto-fix" if fixable else "needs-human"]
        url = gh(
            "issue",
            "create",
            "--title",
            f"Update held back: {unit}",
            "--body",
            body,
            *[a for label in labels for a in ("--label", label)],
        ).strip()
        e["issue"] = int(url.rsplit("/", 1)[1])
    elif fixable and e.get("handled") and e["handled"] != e["signature"]:
        gh(
            "issue",
            "comment",
            str(e["issue"]),
            "--body",
            f"The failure changed, so the fix agent runs again.\n\n{details}",
        )
        gh(
            "issue",
            "edit",
            str(e["issue"]),
            "--add-label",
            "auto-fix",
            *[a for v in VERDICT_LABELS for a in ("--remove-label", v)],
            check=False,
        )
    if fixable and e.get("handled") != e["signature"]:
        gh("workflow", "run", "update-fix.yml", "-f", f"issue={e['issue']}", "-f", f"unit={unit}")
        e["handled"] = e["signature"]


# --- PR / commit rendering ---------------------------------------------------


def render_commit(meta: dict) -> str:
    lines = [f"chore(update): update inputs and packages ({meta['date']})", ""]
    if meta["units"]:
        lines += ["Updated:"] + [f"- {u}: {v['old']} -> {v['new']}" for u, v in sorted(meta["units"].items())]
    if meta["held"]:
        lines += ["", "Held back:"] + [f"- {u}: {k}" for u, k in sorted(meta["held"].items())]
    if meta["update_failures"]:
        lines += ["", "Failed to update:"] + [
            f"- {u}: {k}" for u, k in sorted(meta["update_failures"].items())
        ]
    return "\n".join(lines) + "\n"


def render_pr_body(meta: dict, state: dict) -> str:
    lines = [f"Nightly update for {meta['date']}. Automerges once `CI gate` passes.", ""]
    if meta["units"]:
        lines += ["| Updated | From | To |", "| --- | --- | --- |"]
        lines += [f"| `{u}` | {v['old']} | {v['new']} |" for u, v in sorted(meta["units"].items())]
    if meta["held"] or meta["update_failures"]:
        lines += ["", "**Held back** (retried tomorrow):", ""]
        for u, k in sorted({**meta["held"], **meta["update_failures"]}.items()):
            e = state["units"].get(u, {})
            n = len(e.get("nights", [])) or 1
            issue = f", #{e['issue']}" if e.get("issue") else ""
            lines.append(f"- `{u}`: {k}: {e.get('summary', '')} (night {n}/{THRESHOLDS[k]}{issue})")
    return "\n".join(lines) + "\n\n" + embed(meta)


def find_update_pr() -> dict | None:
    prs = gh_json(
        "pr", "list", "--head", BRANCH, "--state", "open", "--json", "number,body,headRefOid", bot=True
    )
    return prs[0] if prs else None


def enable_automerge(pr: int) -> None:
    # `--auto` merges on the spot when nothing is required, so refuse unless main requires checks.
    repo = os.environ["GITHUB_REPOSITORY"]
    rules = gh_json("api", f"repos/{repo}/rules/branches/main", bot=True)
    if not any(r["type"] == "required_status_checks" for r in rules):
        raise RuntimeError(
            f"main has no required status checks; leaving PR #{pr} open instead of auto-merging"
        )
    gh("pr", "merge", "--auto", "--rebase", str(pr), bot=True)


# --- cache gate --------------------------------------------------------------


def cache_miss(attr: str, cache: str) -> str | None:
    """Why `cache` can't serve `attr`'s output yet; None if it can or `attr` fails to evaluate (CI triage owns that)."""
    try:
        out = run("nix", "eval", "--raw", f".#{attr}.outPath")
    except RuntimeError as e:
        print(f"{attr} doesn't evaluate; leaving it to CI:\n{e}")
        return None
    url = f"{cache}/{Path(out).name.split('-', 1)[0]}.narinfo"
    try:
        urllib.request.urlopen(urllib.request.Request(url, method="HEAD"), timeout=60).close()
    except OSError as e:
        return f"{cache} can't serve {out} yet ({e})"
    return None


def gate_cached_inputs(base_ref: str) -> dict[str, str]:
    """Revert each CACHE_GATED input that moved since `base_ref` to its locked rev there unless its build
    is cached; return {input: reason} for the reverted ones."""
    base, held = read_lock(base_ref), {}
    for name, (attr, cache) in CACHE_GATED.items():
        cand = read_lock(None)
        ref, bref = root_inputs(cand).get(name), root_inputs(base).get(name)
        if not (isinstance(ref, str) and isinstance(bref, str)) or (
            cand["nodes"][ref].get("locked") == base["nodes"][bref].get("locked")
        ):
            continue
        if reason := cache_miss(attr, cache):
            write_lock(graft_input(cand, base, name), ROOT)
            held[name] = reason
            print(f"{name}: held at {describe_locked(base['nodes'][bref])}: {reason}")
    return held


# --- nightly -----------------------------------------------------------------


def cmd_flake_update(args) -> None:
    """Update all inputs; if that fails, update them one by one. Record the inputs that fail to update
    or that the cache gate holds back as {input: [kind, error]}."""
    failures = {}
    p = subprocess.run(["nix", "flake", "update"], cwd=ROOT, capture_output=True, text=True)
    if p.returncode != 0:
        print(f"nix flake update failed, retrying input by input:\n{p.stderr}")
        run("git", "checkout", "--", "flake.lock")
        lock = read_lock(None)
        for name, ref in sorted(root_inputs(lock).items()):
            if not isinstance(ref, str) or lock["nodes"][ref].get("locked", {}).get("type") == "path":
                continue
            q = subprocess.run(["nix", "flake", "update", name], cwd=ROOT, capture_output=True, text=True)
            if q.returncode != 0:
                failures[name] = ["fetch", "\n".join(q.stderr.strip().splitlines()[-20:])]
                print(f"{name}: FAILED\n{failures[name][1]}")
    failures |= {name: ["cache", reason] for name, reason in gate_cached_inputs("HEAD").items()}
    args.json.write_text(json.dumps(failures, indent=2) + "\n")


def cmd_nightly(args) -> None:
    packages = json.loads(args.packages_json.read_text())
    flake_failures = json.loads(args.flake_json.read_text())
    number, state = load_state()

    errors = {package_unit(n): ("script", r["error"]) for n, r in packages.items() if r["status"] == "failed"}
    errors |= {name: (kind, error) for name, (kind, error) in flake_failures.items()}
    for unit, (kind, error) in errors.items():
        summary = error.strip().splitlines()[-1].strip()[:200] if error.strip() else kind
        hold(state, unit, kind, summary, hashlib.sha1(f"{kind}|{summary}".encode()).hexdigest()[:12])
        escalate(state, unit, f"```\n{error[-6000:]}\n```")
    for unit, e in list(state["units"].items()):
        if e["kind"] in UPDATE_KINDS and unit not in errors:
            clear(state, unit, "It updates again.")

    units = changed_units("origin/main", package_versions=packages)
    meta = {
        "date": today(),
        "units": units,
        "held": {},
        "update_failures": {u: k for u, (k, _e) in errors.items()},
        "passes": 0,
    }
    save_state(number, state)

    pr = find_update_pr()
    if not units:
        print("Nothing to update.")
        if pr:
            gh(
                "pr",
                "close",
                str(pr["number"]),
                "--comment",
                "Superseded: nothing to update tonight.",
                bot=True,
            )
        return

    run("git", "checkout", "-B", BRANCH)
    run("git", "add", "flake.lock", "pkgs")
    subprocess.run(
        ["git", "commit", "-q", "-F", "-"], cwd=ROOT, input=render_commit(meta), text=True, check=True
    )
    run("git", "push", "--force", "origin", BRANCH)

    body = render_pr_body(meta, state)
    if pr:
        gh("pr", "edit", str(pr["number"]), "--body", body, bot=True)
        number = pr["number"]
    else:
        url = gh(
            "pr",
            "create",
            "--head",
            BRANCH,
            "--base",
            "main",
            "--title",
            "chore(update): update inputs and packages",
            "--body",
            body,
            "--label",
            "dependencies",
            "--label",
            "automated",
            bot=True,
        ).strip()
        number = int(url.rsplit("/", 1)[1])
    enable_automerge(number)


# --- triage ------------------------------------------------------------------

CANNOT_BUILD = re.compile(r"error: Cannot build '(/nix/store/[^']+\.drv)'")
LEGACY_BUILDER = re.compile(r"builder for '(/nix/store/[^']+\.drv)' failed")
INFLIGHT = re.compile(r"update-triage: timeout-inflight (/nix/store/\S+\.drv)")
TIMESTAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ?")


@dataclass
class Failure:
    job: str
    kind: str  # build | timeout | eval
    attrs: list[str]
    drv: str | None = None
    excerpt: str = ""
    units: set[str] = field(default_factory=set)
    # Units whose revert only re-hashes the failed drv (same name): it merely depends on them.
    weak: set[str] = field(default_factory=set)

    @property
    def name(self) -> str:
        return drv_name(self.drv) if self.drv else self.job


def drv_name(path: str) -> str:
    return re.sub(r"^/nix/store/[a-z0-9]{32}-|\.drv$", "", path)


def clean_log(raw: str) -> list[str]:
    return [TIMESTAMP.sub("", line.split("\t", 2)[-1]) for line in raw.splitlines()]


def parse_job_log(job: str, attrs: list[str], lines: list[str]) -> list[Failure]:
    failures: dict[str, Failure] = {}
    for i, line in enumerate(lines):
        if m := INFLIGHT.search(line):
            failures.setdefault(
                m[1],
                Failure(job, "timeout", attrs, m[1], "Still building when the 100 min step timeout hit."),
            )
            continue
        m = CANNOT_BUILD.search(line)
        root = m and any("builder failed" in nxt for nxt in lines[i + 1 : i + 3])
        if not root and (m := LEGACY_BUILDER.search(line)):
            root = True
        if root and m[1] not in failures:
            block = [line]
            for nxt in lines[i + 1 : i + 60]:
                if CANNOT_BUILD.search(nxt):
                    break
                block.append(nxt)
            failures[m[1]] = Failure(job, "build", attrs, m[1], "\n".join(block))
    return list(failures.values())


def job_attrs(job: str) -> list[str] | None:
    if m := re.fullmatch(r"build \((.+)\)", job):
        return [f"nixosConfigurations.{m[1]}.config.system.build.toplevel"]
    if job == "darwin":
        return ["darwinConfigurations.macbook.system"]
    if job == "check":
        names = json.loads(
            run("nix", "eval", "--json", ".#checks.x86_64-linux", "--apply", "builtins.attrNames")
        )
        return [f"checks.x86_64-linux.{n}" for n in names]
    return None


def instantiate(tree: Path, attr: str) -> tuple[set[str] | None, str]:
    """Return the drv closure of `attr` evaluated in `tree` (None if eval fails) and nix's stderr."""
    p = subprocess.run(
        ["nix", "eval", "--raw", f".#{attr}.drvPath"], cwd=tree, capture_output=True, text=True
    )
    if p.returncode != 0:
        return None, p.stderr
    return set(run("nix-store", "-qR", p.stdout.strip()).split()), p.stderr


def attribute(failures: list[Failure], units: list[str], base_ref: str) -> None:
    attrs = sorted({a for f in failures for a in f.attrs})
    cand = {a: instantiate(ROOT, a) for a in attrs}
    # A drv-less failure is only attributable if the candidate really fails to evaluate.
    for f in failures:
        if not f.drv and (err := next((cand[a][1] for a in f.attrs if cand[a][0] is None), None)):
            f.excerpt = "\n".join(err.splitlines()[-40:])

    def try_unit(unit: str) -> tuple[str, dict]:
        tmp = Path(tempfile.mkdtemp(prefix="triage-"))
        tree = tmp / "tree"
        try:
            run("git", "worktree", "add", "-q", "--detach", str(tree), "HEAD")
            revert_units(tree, [unit], base_ref)
            return unit, {a: instantiate(tree, a)[0] for a in attrs}
        finally:
            run("git", "worktree", "remove", "--force", str(tree), check=False)
            shutil.rmtree(tmp, ignore_errors=True)

    # A unit is a direct cause when reverting it removes the failed package by name (other
    # version or gone); a unit that only re-hashes it (e.g. nixpkgs under a pkgs/ package) is blamed
    # only when no direct cause exists.
    with ThreadPoolExecutor(max_workers=2) as pool:
        for unit, variant in pool.map(try_unit, units):
            for f in failures:
                for a in f.attrs:
                    if f.drv:
                        in_cand = cand[a][0] is not None and f.drv in cand[a][0]
                        if in_cand and variant[a] is not None and f.drv not in variant[a]:
                            names = {drv_name(p) for p in variant[a] if p.endswith(".drv")}
                            (f.weak if f.name in names else f.units).add(unit)
                    elif cand[a][0] is None and variant[a] is not None:
                        f.units.add(unit)
    for f in failures:
        f.units = f.units or f.weak


def cmd_triage(args) -> None:
    run_info = gh_json("run", "view", str(args.run_id), "--json", "headSha,attempt,jobs")
    head = run("git", "ls-remote", "origin", f"refs/heads/{BRANCH}").split()[:1]
    if head != [run_info["headSha"]]:
        print("auto/update has moved on since this CI run; nothing to do.")
        return
    pr = find_update_pr()
    if not pr:
        print("No open update PR.")
        return
    meta = extract(pr["body"])
    if meta.get("passes", 0) >= MAX_TRIAGE_PASSES:
        print("Triage pass limit reached for today.")
        return
    base_ref = run("git", "merge-base", "HEAD", "origin/main").strip()

    failures, unknown = [], []
    for job in run_info["jobs"]:
        if job["conclusion"] not in ("failure", "timed_out") or job["name"] == "CI gate":
            continue
        attrs = job_attrs(job["name"])
        if attrs is None:
            unknown.append(job["name"])
            continue
        raw = gh("run", "view", "--job", str(job["databaseId"]), "--log-failed", check=False)
        found = parse_job_log(job["name"], attrs, clean_log(raw))
        failures += found or [Failure(job["name"], "eval", attrs)]

    units = sorted(changed_units(base_ref))
    print(f"Failures: {[f.name for f in failures]}; unknown jobs: {unknown}; units: {units}")
    attribute(failures, units, base_ref)
    unattributed = [f for f in failures if not f.units]
    held: dict[str, list[Failure]] = {}
    for f in failures:
        for u in f.units:
            held.setdefault(u, []).append(f)
    for u, fs in sorted(held.items()):
        print(f"Hold back {u}: {[f'{f.job}:{f.name}' for f in fs]}")
    for f in unattributed:
        print(f"Unattributed: {f.job}:{f.name}")
    if args.dry_run:
        return

    number, state = load_state()
    for unit, fs in held.items():
        kind = (
            "timeout"
            if all(f.kind == "timeout" for f in fs)
            else next(f.kind for f in fs if f.kind != "timeout")
        )
        names = sorted({f.name for f in fs})
        jobs = sorted({f.job for f in fs})
        summary = f"{', '.join(names[:3])}{' …' if len(names) > 3 else ''} ({', '.join(jobs)})"
        signature = hashlib.sha1(f"{unit}|{kind}|{names}".encode()).hexdigest()[:12]
        hold(state, unit, kind, summary, signature)
        details = "\n\n".join(
            f"<details><summary>{f.job}: <code>{f.name}</code></summary>\n\n```\n{f.excerpt[-6000:]}\n```\n</details>"
            for f in fs[:5]
        )
        details += f"\n\nFrom CI run https://github.com/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{args.run_id}."
        escalate(state, unit, details)

    if held:
        revert_units(ROOT, sorted(held), base_ref)
        meta["held"] = {**meta.get("held", {}), **{u: state["units"][u]["kind"] for u in held}}
        meta["units"] = {u: v for u, v in meta["units"].items() if u not in meta["held"]}
        meta["passes"] = meta.get("passes", 0) + 1
        save_state(number, state)
        if not changed_units(base_ref):
            gh("pr", "close", str(pr["number"]), "--comment", "Every update was held back tonight.", bot=True)
            return
        run("git", "add", "flake.lock", "pkgs")
        subprocess.run(
            ["git", "commit", "-q", "--amend", "-F", "-"],
            cwd=ROOT,
            input=render_commit(meta),
            text=True,
            check=True,
        )
        run("git", "push", f"--force-with-lease={BRANCH}:{run_info['headSha']}", "origin", f"HEAD:{BRANCH}")
        gh("pr", "edit", str(pr["number"]), "--body", render_pr_body(meta, state), bot=True)
    elif unattributed or unknown:
        save_state(number, state)

    if (unattributed or unknown) and not held:
        if run_info["attempt"] == 1:
            print("Nothing attributable; re-running the failed jobs once in case it was flaky.")
            gh("run", "rerun", str(args.run_id), "--failed")
        elif number:
            names = ", ".join([f"`{f.job}: {f.name}`" for f in unattributed] + [f"`{j}`" for j in unknown])
            gh(
                "issue",
                "comment",
                str(number),
                "--body",
                f"@{owner()} the update PR #{pr['number']} fails in a way no single update explains: {names}. "
                f"See https://github.com/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{args.run_id}.",
            )


# --- landed ------------------------------------------------------------------


def cmd_landed(args) -> None:
    pr = gh_json("pr", "view", str(args.pr), "--json", "body,headRefName")
    number, state = load_state()
    if number is None:
        return
    if pr["headRefName"].startswith(FIX_PREFIX):
        # A fix PR carries its unit's bump (prepare-fix), so that unit landed with it.
        slug = pr["headRefName"].removeprefix(FIX_PREFIX)
        landed = [u for u in state["units"] if fix_slug(u) == slug]
    else:
        held = extract(pr["body"]).get("held", {})
        landed = [u for u in state["units"] if u not in held]
    for unit in landed:
        if state["units"][unit]["kind"] not in UPDATE_KINDS:
            clear(state, unit, f"Landed in #{args.pr}.")
    save_state(number, state)


# --- fix agent ---------------------------------------------------------------


def fix_slug(unit: str) -> str:
    """The unit's fix branch is FIX_PREFIX + this."""
    return re.sub(r"[^a-z0-9-]+", "-", unit.lower()).strip("-")


def bump(unit: str) -> None:
    """Commit `unit`'s held-back update as `chore(update): bump <unit>`; nothing if its updater fails."""
    if is_package(unit):
        name = unit.removeprefix("pkgs/")
        out = Path(tempfile.mkstemp(suffix=".json")[1])
        run(
            sys.executable,
            str(Path(__file__).with_name("update_packages.py")),
            "--only",
            name,
            "--json",
            str(out),
        )
        if json.loads(out.read_text())[name]["status"] == "failed":
            return  # the updater itself is what needs fixing
    else:
        run("nix", "flake", "update", unit)
    if run("git", "status", "--porcelain").strip():
        run("nix", "fmt", check=False)
        run("git", "add", "-A")
        run("git", "commit", "-q", "-m", f"chore(update): bump {unit}")


def cmd_prepare_fix(args) -> None:
    bump(args.unit)
    set_output(head=run("git", "rev-parse", "HEAD").strip())


def fenced(text: str, lang: str = "") -> str:
    """`text` in a code fence longer than any backtick run in it, so untrusted text can't close it."""
    fence = "`" * max(3, 1 + max(map(len, re.findall(r"`+", text)), default=0))
    return f"{fence}{lang}\n{text}\n{fence}"


def apply_fix(unit: str, patch: bytes) -> str | None:
    """Stage the agent's `patch` on a fresh bump of `unit`; return why it can't be pushed, else None.

    The bump runs first because nothing from the patched tree may run here (this job holds BOT_TOKEN).
    """
    if not patch.strip():
        return "Claimed a fix but changed nothing."
    bump(unit)
    p = subprocess.run(["git", "apply", "--index", "-"], cwd=ROOT, input=patch, capture_output=True)
    if p.returncode != 0:
        return f"Its patch doesn't apply to a fresh bump of `{unit}`:\n\n{fenced(p.stderr.decode(errors='replace'))}"
    # --no-renames: a rename out of .github/ must show its old path too.
    files = run("git", "diff", "--cached", "--no-renames", "--name-only").split()
    if bad := [f for f in files if not f.startswith(FIX_ALLOWED)]:
        return (
            f"It touches {', '.join(f'`{f}`' for f in bad)}, outside `{' '.join(FIX_ALLOWED)}`. "
            "Not pushed: CI would run that with secrets before any review."
        )
    return None


def cmd_finish_fix(args) -> None:
    """Act on the fix agent's verdict (env VERDICT, JSON) and patch (env PATCH, base64 `git diff` against
    its bump). Both come from the agent's job, which the agent could fully control: treat them as data and
    run this from a trusted checkout of the commit the agent started from.
    """
    try:
        verdict = json.loads(os.environ.get("VERDICT") or "{}")
    except json.JSONDecodeError:
        verdict = {}
    if not isinstance(verdict, dict):
        verdict = {}
    decision = verdict.get("verdict")
    decision = decision if decision in VERDICT_LABELS else "needs-human"
    summary = str(verdict.get("summary") or "The fix agent returned no verdict.")
    if decision == "fix-pr":
        raw = os.environ.get("PATCH") or ""
        try:
            patch = base64.b64decode(raw, validate=True)
        except ValueError:
            patch, reason = b"", f"Its patch couldn't be handed over ({raw[:40]!r}, e.g. over the size cap)."
        else:
            reason = apply_fix(args.unit, patch)
        if reason:
            decision = "needs-human"
            summary = f"{reason}\n\n{summary}"
            if patch.strip():
                text = patch.decode(errors="replace")[:20000]
                summary += f"\n\n<details><summary>The agent's patch</summary>\n\n{fenced(text, 'diff')}\n</details>"

    issue = str(args.issue)
    gh(
        "issue",
        "edit",
        issue,
        "--add-label",
        decision,
        *[a for v in VERDICT_LABELS if v != decision for a in ("--remove-label", v)],
        check=False,
    )
    if decision != "fix-pr":
        ping = f"@{owner()} " if decision == "needs-human" else ""
        gh("issue", "comment", issue, "--body", f"{ping}**Fix agent verdict: {decision}**\n\n{summary}")
        return

    slug = fix_slug(args.unit)
    branch = f"{FIX_PREFIX}{slug}"
    title = str(verdict.get("title") or f"fix({slug}): make the {args.unit} update build")
    run("git", "checkout", "-B", branch)
    subprocess.run(
        ["git", "commit", "-q", "-F", "-"],
        cwd=ROOT,
        input=f"{title}\n\n{summary}\n\nRefs #{issue}\n",
        text=True,
        check=True,
    )
    repo = os.environ["GITHUB_REPOSITORY"]
    run(
        "git",
        "push",
        "--force",
        f"https://x-access-token:{os.environ['BOT_TOKEN']}@github.com/{repo}.git",
        f"HEAD:refs/heads/{branch}",
    )
    body = (
        f"{summary}\n\nRefs #{issue}. Held-back unit: `{args.unit}`.\n\n"
        "Automerges only if the hard rules and the review agent both approve."
    )
    prs = gh_json("pr", "list", "--head", branch, "--state", "open", "--json", "number", bot=True)
    if prs:
        gh("pr", "edit", str(prs[0]["number"]), "--title", title, "--body", body, bot=True)
        url = f"#{prs[0]['number']}"
    else:
        url = gh(
            "pr",
            "create",
            "--head",
            branch,
            "--base",
            "main",
            "--title",
            title,
            "--body",
            body,
            "--label",
            "automated",
            bot=True,
        ).strip()
    gh("issue", "comment", issue, "--body", f"**Fix agent verdict: fix-pr** → {url}\n\n{summary}")


def cmd_fix_rules(args) -> None:
    """Print {"ok", "reasons"} for the commits on HEAD that aren't on origin/main."""
    reasons = []
    commits = run("git", "rev-list", "--reverse", "origin/main..HEAD").split()
    if not 1 <= len(commits) <= 2:
        reasons.append(f"expected 1-2 commits (optional bump + fix), found {len(commits)}")
    fix = commits[-1] if commits else "HEAD"
    if len(commits) == 2:
        subject = run("git", "log", "-1", "--format=%s", commits[0]).strip()
        files = run("git", "diff", "--no-renames", "--name-only", f"{commits[0]}^", commits[0]).split()
        if not subject.startswith("chore(update): bump") or any(
            f != "flake.lock" and not f.startswith("pkgs/") for f in files
        ):
            reasons.append("first commit is not a plain `chore(update): bump` of flake.lock/pkgs")

    files = run("git", "diff", "--no-renames", "--name-only", f"{fix}^", fix).split()
    if bad := [f for f in files if not f.startswith(FIX_ALLOWED)]:
        reasons.append(f"touches paths outside the allowlist: {', '.join(bad)}")
    if len(files) > FIX_MAX_FILES:
        reasons.append(f"touches {len(files)} files (max {FIX_MAX_FILES})")
    numstat = [line.split("\t") for line in run("git", "diff", "--numstat", f"{fix}^", fix).splitlines()]
    changed = sum(int(a) + int(d) for a, d, _ in numstat if a != "-")
    if changed > FIX_MAX_LINES:
        reasons.append(f"changes {changed} lines (max {FIX_MAX_LINES})")
    diff = run("git", "diff", "-U0", f"{fix}^", fix).splitlines()
    added = [line[1:] for line in diff if line.startswith("+") and not line.startswith("+++")]
    removed = [line[1:] for line in diff if line.startswith("-") and not line.startswith("---")]
    for pat in FIX_FORBIDDEN_ADDED:
        if any(re.search(pat, line) for line in added):
            reasons.append(f"adds `{pat}`")
    for pat in FIX_FORBIDDEN_REMOVED:
        if any(re.search(pat, line) for line in removed):
            reasons.append(f"removes a line matching `{pat}`")

    print(json.dumps({"ok": not reasons, "reasons": reasons}))
    set_output(ok=str(not reasons).lower(), reasons=json.dumps(reasons))


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser(
        "flake-update",
        help="nix flake update, falling back to per-input so one bad fetch can't block the rest, then the cache gate",
    )
    s.add_argument("--json", type=Path, required=True)
    s = sub.add_parser("nightly", help="commit the current tree to auto/update and open/refresh its PR")
    s.add_argument("--packages-json", type=Path, required=True)
    s.add_argument("--flake-json", type=Path, required=True)
    s = sub.add_parser("triage", help="attribute a failed CI run on auto/update to updated units and hold them back")
    s.add_argument("--run-id", type=int, required=True)
    s.add_argument("--dry-run", action="store_true", help="attribute only; no pushes or GitHub writes")
    s = sub.add_parser("landed", help="clear held-back state for units that landed with a merged update or fix PR")
    s.add_argument("--pr", type=int, required=True)
    s = sub.add_parser("prepare-fix", help="bump one unit on the current branch so the fix agent works on the new version")
    s.add_argument("--unit", required=True)
    s = sub.add_parser("finish-fix", help="act on the fix agent's verdict and patch (env VERDICT, PATCH); trusted job only")
    s.add_argument("--issue", type=int, required=True)
    s.add_argument("--unit", required=True)
    sub.add_parser("fix-rules", help="check the hard automerge rules for an auto/fix-* branch")
    sub.add_parser("ensure-labels", help="create or update the bot's GitHub labels")
    sub.add_parser("cache-gate", help="hold CACHE_GATED inputs at HEAD's lock until their build is cached")
    args = p.parse_args()
    {
        "flake-update": cmd_flake_update,
        "nightly": cmd_nightly,
        "triage": cmd_triage,
        "landed": cmd_landed,
        "prepare-fix": cmd_prepare_fix,
        "finish-fix": cmd_finish_fix,
        "fix-rules": cmd_fix_rules,
        "ensure-labels": lambda _a: ensure_labels(),
        "cache-gate": lambda _a: gate_cached_inputs("HEAD"),
    }[args.cmd](args)


if __name__ == "__main__":
    main()
