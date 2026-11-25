#!/usr/bin/env python3
"""Publish the agents checkout's plugins and skills as immutable store snapshots.

`agents update NAME` copies the checkout's working tree (tracked files plus untracked files
that git does not ignore) into a temporary directory, builds the requested plugin halves and
the skills tree from that snapshot with Nix, keeps a GC root for the result, and only then
replaces `$XDG_STATE_HOME/agents-updates/current.json` in one atomic rename. The checkout
itself is never written to: git is asked what its working tree holds, and nothing is
pulled, committed, stashed or switched.

A launched harness asks `agents resolve` for the effective plugin and skill paths, which
merges those overrides over the baseline that Nix pins (AGENTS_BASELINE). A variant that
current.json does not override falls back to the baseline, so a partial update is safe.

The published tree must be self-contained: a symlink that would resolve outside the snapshot
(or at a file the snapshot does not carry) is refused rather than copied, because a store
copy that still points into the checkout could change under a harness later.

Generation roots are never removed. A running session may still load an older snapshot
(Claude Code resolves plugin paths at launch, pi sessions hold them in memory), so only a
human can tell when an old root is dead weight; `nix-collect-garbage` will not collect those
paths until the root symlinks under roots/ are deleted by hand.

Environment (set by the Nix wrapper):
  AGENTS_BASELINE  JSON file: {"revision": str,
                               "plugins": {name: {"pi": path|null, "claude": path|null}},
                               "skills": {name: path}}
  AGENTS_CHECKOUT  the agents checkout
  AGENTS_NIXPKGS   nixpkgs source store path
  AGENTS_CLAUDE    the claude-code package store path (unwrapped: mkClaudePlugin runs
                   `claude plugin validate`, which a wrapper's injected --plugin-dir breaks)
  AGENTS_SYSTEM    e.g. x86_64-linux
Optional:
  XDG_STATE_HOME            default ~/.local/state
  AGENTS_UPDATE_LOCK_TIMEOUT  seconds to wait for a concurrent update (default 600)
  AGENTS_UPDATE_KEEP_SNAPSHOT=1  keep the temporary snapshot even on success
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path

PROG = "agents"
STATE_DIR_NAME = "agents-updates"
STATE_FILE = "current.json"
HARNESSES = ("pi", "claude")
LIVE_CHOICES = ("pi", "claude", "all")

# A name becomes a directory under apps/ or skills/ and a Nix attribute name; keep it to
# characters that are safe in both and cannot traverse (`..`, leading '.').
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")

# A request the bridge never answered is replaced after this long, so a crashed session
# cannot wedge the next update.
REQUEST_TTL = 600.0


class UpdateError(Exception):
    """A failure worth one line to the user; `main` prints it and returns 1."""


class Console:
    """stdout/stderr, injectable so tests can capture them."""

    def __init__(self, out=None, err=None):
        self.out = out if out is not None else sys.stdout
        self.err = err if err is not None else sys.stderr

    def say(self, message=""):
        print(message, file=self.out)

    def warn(self, message):
        print(message, file=self.err)


# --------------------------------------------------------------------------------------------
# Environment and names


def state_home(env):
    home = env.get("HOME") or str(Path.home())
    return Path(env.get("XDG_STATE_HOME") or os.path.join(home, ".local", "state"))


def state_dir(env):
    return state_home(env) / STATE_DIR_NAME


def child_environment(env):
    """The environment subprocesses get: the ambient one plus this CLI's own settings.

    In production `env` is os.environ already; keeping the merge makes an interpreter that
    was handed a different mapping (tests, or a wrapper that builds one) still work.
    """
    merged = dict(os.environ)
    merged.update({key: value for key, value in env.items() if isinstance(value, str)})
    return merged


def lock_timeout(env):
    try:
        return float(env.get("AGENTS_UPDATE_LOCK_TIMEOUT") or 600)
    except ValueError:
        raise UpdateError("AGENTS_UPDATE_LOCK_TIMEOUT is not a number") from None


@dataclass(frozen=True)
class Context:
    baseline_path: Path
    checkout: Path
    nixpkgs: Path
    claude: Path
    system: str
    state: Path
    lock_timeout: float
    environment: dict

    @property
    def store(self):
        """The store directory: nixpkgs is a store path, so its parent is the store."""
        return self.nixpkgs.parent

    @classmethod
    def from_env(cls, env):
        names = ("AGENTS_BASELINE", "AGENTS_CHECKOUT", "AGENTS_NIXPKGS", "AGENTS_CLAUDE", "AGENTS_SYSTEM")
        missing = [name for name in names if not env.get(name)]
        if missing:
            raise UpdateError(
                f"{', '.join(missing)} not set: run me from the wrapper Nix installs, "
                "or set them by hand (see the module header)"
            )
        return cls(
            baseline_path=Path(env["AGENTS_BASELINE"]),
            checkout=Path(env["AGENTS_CHECKOUT"]),
            nixpkgs=Path(env["AGENTS_NIXPKGS"]),
            claude=Path(env["AGENTS_CLAUDE"]),
            system=env["AGENTS_SYSTEM"],
            state=state_dir(env),
            lock_timeout=lock_timeout(env),
            environment=child_environment(env),
        )


def validate_names(names):
    for name in names:
        if not NAME_RE.match(name) or ".." in name:
            raise UpdateError(
                f"bad name {name!r}: use letters, digits, '.', '_' and '-', not starting with '.'"
            )


def repository_path(root, *parts):
    """Join under `root`, refusing a symlink that leaves it (a plugin or skill must stay inside)."""
    candidate = Path(root, *parts)
    real_root = Path(os.path.realpath(root))
    real = Path(os.path.realpath(candidate))
    if real != real_root and real_root not in real.parents:
        raise UpdateError(f"{candidate} resolves outside {root}")
    return candidate


# --------------------------------------------------------------------------------------------
# Baseline and state


@dataclass(frozen=True)
class Baseline:
    revision: str
    plugins: dict
    skills: dict


def _revision(value, where):
    if not isinstance(value, str):
        raise UpdateError(f"{where} must be a string, not {type(value).__name__}")
    return value


def load_baseline(path):
    try:
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
    except OSError as exc:
        raise UpdateError(f"cannot read AGENTS_BASELINE {path}: {exc.strerror or exc}") from None
    except ValueError as exc:
        raise UpdateError(f"AGENTS_BASELINE {path} is not JSON: {exc}") from None
    if not isinstance(raw, dict):
        raise UpdateError(f"AGENTS_BASELINE {path} must hold a JSON object")
    revision = _revision(raw.get("revision", ""), f"{path}: revision")

    plugins = {}
    raw_plugins = raw.get("plugins")
    if raw_plugins is None:
        raw_plugins = {}
    if not isinstance(raw_plugins, dict):
        raise UpdateError(f"{path}: plugins must be an object")
    for name, variants in raw_plugins.items():
        if not isinstance(variants, dict):
            raise UpdateError(f"{path}: plugins.{name} must be an object")
        entry = {}
        for harness in HARNESSES:
            value = variants.get(harness)
            if value is not None and not isinstance(value, str):
                raise UpdateError(f"{path}: plugins.{name}.{harness} must be a path or null")
            entry[harness] = value
        plugins[name] = entry

    skills = {}
    raw_skills = raw.get("skills")
    if raw_skills is None:
        raw_skills = {}
    if not isinstance(raw_skills, dict):
        raise UpdateError(f"{path}: skills must be an object")
    for name, value in raw_skills.items():
        if not isinstance(value, str):
            raise UpdateError(f"{path}: skills.{name} must be a path")
        skills[name] = value

    return Baseline(revision=revision, plugins=plugins, skills=skills)


def load_state(state):
    """(plugins, skills) from current.json; an absent file is an empty state."""
    path = Path(state) / STATE_FILE
    if not path.exists():
        return {}, {}
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise UpdateError(f"cannot read {path}: {exc.strerror or exc}") from None
    except ValueError as exc:
        raise UpdateError(f"{path} is not JSON: {exc}") from None
    if not isinstance(raw, dict):
        raise UpdateError(f"{path} must hold a JSON object")

    raw_plugins = raw.get("plugins")
    if raw_plugins is None:
        raw_plugins = {}
    if not isinstance(raw_plugins, dict):
        raise UpdateError(f"{path}: plugins must be an object")
    plugins = {}
    for name, entry in raw_plugins.items():
        if not isinstance(entry, dict):
            raise UpdateError(f"{path}: plugins.{name} must be an object")
        kept = {harness: entry.get(harness) for harness in HARNESSES}
        for harness, value in kept.items():
            if value is not None and not isinstance(value, str):
                raise UpdateError(f"{path}: plugins.{name}.{harness} must be a path or null")
        kept["baseline"] = _revision(entry.get("baseline", ""), f"{path}: plugins.{name}.baseline")
        plugins[name] = kept

    raw_skills = raw.get("skills")
    if raw_skills is None:
        raw_skills = {}
    if not isinstance(raw_skills, dict):
        raise UpdateError(f"{path}: skills must be an object")
    skills = {}
    for name, entry in raw_skills.items():
        if not isinstance(entry, dict):
            raise UpdateError(f"{path}: skills.{name} must be an object")
        path_value = entry.get("path")
        if not isinstance(path_value, str):
            raise UpdateError(f"{path}: skills.{name}.path must be a path")
        skills[name] = {
            "path": path_value,
            "baseline": _revision(entry.get("baseline", ""), f"{path}: skills.{name}.baseline"),
        }

    return plugins, skills


def write_json_atomic(path, data):
    """Write `data` beside `path` and rename it over, so a reader never sees a partial file."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(data, stream, indent=2, sort_keys=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(temporary)
        raise
    # fsync the directory so the rename itself survives a crash.
    with contextlib.suppress(OSError):
        descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


def save_state(state, plugins, skills):
    payload = {
        "plugins": {name: _ordered_plugin(plugins[name]) for name in sorted(plugins)},
        "skills": {name: skills[name] for name in sorted(skills)},
    }
    write_json_atomic(Path(state) / STATE_FILE, payload)


def _ordered_plugin(entry):
    return {**{harness: entry.get(harness) for harness in HARNESSES}, "baseline": entry.get("baseline", "")}


@contextlib.contextmanager
def state_lock(state, timeout):
    """Serialise updates and resets; the lock lives beside the state it guards."""
    Path(state).mkdir(parents=True, exist_ok=True)
    lock_path = Path(state) / "lock"
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
    deadline = time.monotonic() + timeout
    waited = False
    try:
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if not waited:
                    print(f"{PROG}: waiting for another update to finish ({lock_path})", file=sys.stderr)
                    waited = True
                if time.monotonic() >= deadline:
                    raise UpdateError(f"another agents update holds {lock_path}") from None
                time.sleep(0.1)
        try:
            yield
        finally:
            with contextlib.suppress(OSError):
                fcntl.flock(descriptor, fcntl.LOCK_UN)
    finally:
        os.close(descriptor)


def effective(baseline, plugins, skills):
    """The paths a harness should load: overrides win, a missing variant inherits the baseline."""
    resolved_plugins = {}
    for name in sorted(set(baseline.plugins) | set(plugins)):
        base = baseline.plugins.get(name) or {}
        override = plugins.get(name) or {}
        resolved_plugins[name] = {
            harness: override.get(harness) or base.get(harness) for harness in HARNESSES
        }
    resolved_skills = {}
    for name in sorted(set(baseline.skills) | set(skills)):
        override = skills.get(name) or {}
        resolved_skills[name] = override.get("path") or baseline.skills.get(name)
    return {"plugins": resolved_plugins, "skills": resolved_skills}


# --------------------------------------------------------------------------------------------
# The checkout snapshot


def git(checkout, *args, environment=None):
    try:
        proc = subprocess.run(
            ["git", "-C", str(checkout), *args],
            capture_output=True,
            check=False,
            env=environment,
        )
    except FileNotFoundError:
        raise UpdateError("git is not installed") from None
    if proc.returncode != 0:
        detail = (os.fsdecode(proc.stderr) or os.fsdecode(proc.stdout)).strip()
        raise UpdateError(f"git {' '.join(args)} in {checkout} failed: {detail}")
    return proc.stdout


@dataclass
class Snapshot:
    root: Path
    revision: str
    dirty: int
    files: int
    skipped: list = field(default_factory=list)


def publish_snapshot(checkout, destination, environment=None):
    """Copy the checkout's tracked + untracked-not-ignored files into `destination`.

    Reading only: the index and the working tree are left alone, so whatever is staged,
    unstaged or new is what publishes. Submodules (and entries deleted from the working
    tree) are skipped: Nix does not need them to build a plugin.

    Files are copied before symlinks: an absolute link into the checkout is rewritten to the
    same path *inside the snapshot*, which only exists once the files are there.
    """
    checkout = Path(checkout)
    root = Path(os.path.realpath(checkout))
    revision = os.fsdecode(git(checkout, "rev-parse", "HEAD", environment=environment)).strip()
    dirty = len(
        [
            line
            for line in os.fsdecode(
                git(checkout, "status", "--porcelain", environment=environment)
            ).splitlines()
            if line
        ]
    )
    listing = git(
        checkout, "ls-files", "-z", "--cached", "--others", "--exclude-standard", environment=environment
    )

    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    files = 0
    links = []
    skipped = []
    for raw in listing.split(b"\0"):
        if not raw:
            continue
        relative = os.fsdecode(raw)
        source = checkout / relative
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_symlink():
            links.append((relative, source, target))
        elif source.is_file():
            shutil.copy2(source, target)
            files += 1
        else:
            # A submodule gitlink, or a tracked file deleted from the working tree.
            skipped.append(relative)

    for relative, source, target in links:
        try:
            os.symlink(snapshot_link(relative, source, destination, root), target)
        except OSError as exc:
            raise UpdateError(f"cannot copy the symlink {source}: {exc.strerror or exc}") from None
    files += len(links)

    return Snapshot(root=destination, revision=revision, dirty=dirty, files=files, skipped=skipped)


def inside(root, path):
    return path == root or root in path.parents


def snapshot_link(relative, source, destination, root):
    """The link text a published snapshot may keep, or an actionable failure.

    A published tree must refer only to itself: a link into the live checkout (or anywhere
    else outside the snapshot) would let the store copy change under a harness later, and a
    link to a file the snapshot does not carry would only dangle.

    The link text is rewritten to the snapshot's copy of where the chain *ends*. Written in
    place it would be order-dependent - git lists `a -> b` before `b -> skills/x`, so a link
    whose target is another link may not exist yet - and flattening the chain also removes
    the mutable middle: a kept `a -> b` would follow `b` wherever the checkout later moved it.
    """
    link = os.readlink(source)
    resolved = Path(os.path.realpath(source))
    if not inside(root, resolved):
        raise UpdateError(
            f"{source} is a symlink to {link}, which resolves to {resolved}, outside the "
            "checkout; point it at a tracked path inside the checkout, or drop the link, "
            "then retry"
        )
    target = destination / resolved.relative_to(root)
    if not (target.exists() or target.is_symlink()):
        raise UpdateError(
            f"{source} is a symlink to {link}, whose target {resolved} the snapshot does not "
            "carry (it is ignored by git or not committed); commit that target, then retry"
        )
    return os.path.relpath(target, (destination / relative).parent)


def plugin_halves(snapshot_root, name):
    """(pi?, claude?) as the checkout's package.json declares them; None when it is no plugin."""
    manifest = repository_path(snapshot_root, "apps", name, "package.json")
    if not manifest.is_file():
        return None
    try:
        package = json.loads(manifest.read_text(encoding="utf-8"))
    except OSError as exc:
        raise UpdateError(f"cannot read {manifest}: {exc.strerror or exc}") from None
    except ValueError as exc:
        raise UpdateError(f"{manifest} is not JSON: {exc}") from None
    if not isinstance(package, dict):
        raise UpdateError(f"{manifest} must hold a JSON object")
    return tuple(harness for harness in HARNESSES if harness in package)


def plan_update(snapshot_root, names, skills, harness):
    """(halves to build, skill names to publish, halves the checkout offers per plugin)."""
    planned = []
    selected_skills = []
    supported = {}
    if skills:
        for name in names:
            directory = repository_path(snapshot_root, "skills", name)
            if not directory.is_dir():
                raise UpdateError(f"{name} is not a skill in the checkout: no skills/{name}")
            selected_skills.append(name)
        return planned, selected_skills, supported

    for name in names:
        halves = plugin_halves(snapshot_root, name)
        if halves is None:
            raise UpdateError(f"{name} is not a plugin in the checkout: no apps/{name}/package.json")
        if not halves:
            raise UpdateError(f"{name} declares neither a claude nor a pi half in its package.json")
        if harness is not None:
            if harness not in halves:
                raise UpdateError(
                    f"{name} has no {harness} half in the checkout (it has {' and '.join(halves)})"
                )
            chosen = (harness,)
        else:
            chosen = halves
        supported[name] = halves
        planned.extend((name, variant) for variant in chosen)
    return planned, selected_skills, supported


# --------------------------------------------------------------------------------------------
# Nix


def nix_string(value):
    """A Nix string literal. JSON escaping covers what our names and paths contain."""
    return json.dumps(str(value))


def nix_path(value):
    """A Nix path literal; refuse anything a path literal cannot spell."""
    text = str(value)
    if not re.match(r"^[A-Za-z0-9._/+-]+$", text):
        raise UpdateError(f"cannot spell {text!r} as a Nix path")
    return text


def build_expression(context, snapshot, plugin_targets, skills):
    """The linkFarm whose links are this generation's outputs.

    One derivation graphs every requested half plus the whole snapshot, so a single
    `nix build --out-link` both builds and roots all of it: a linkFarm's references keep
    the plugin outputs and the skills snapshot alive for as long as the root exists.
    """
    half_needed = [variant for _, variant in plugin_targets]
    lines = [
        "let",
        f"  flake = builtins.getFlake {nix_string('path:' + str(snapshot))};",
        f"  system = {nix_string(context.system)};",
        f"  pkgs = import {nix_path(context.nixpkgs)} {{ inherit system; config.allowUnfree = true; }};",
        "  plugins = flake.lib.pluginsFor pkgs;",
    ]
    if "claude" in half_needed:
        # mkClaudePlugin runs the supplied claude-code; the wrapper Nix installs injects
        # --plugin-dir and breaks `claude plugin validate`, so the package (not finalPackage)
        # is the right path.
        lines.append(f"  claude-code = builtins.storePath {nix_path(context.claude)};")
        lines.append("  mkClaude = flake.lib.mkClaudePlugin { inherit pkgs claude-code; };")
    lines += ["in", '  pkgs.linkFarm "agents-update-built" [']
    for name, variant in plugin_targets:
        target = f"plugins/{name}/{variant}"
        if variant == "claude":
            source = f"mkClaude {nix_string(name)}"
        else:
            source = f"plugins.{nix_string(name)}.path"
        lines.append(f"    {{ name = {nix_string(target)}; path = {source}; }}")
    if skills:
        lines.append(
            "    { name = \"skills\"; path = builtins.path "
            f"{{ path = {nix_path(snapshot)}; name = \"agents-snapshot\"; }}; }}"
        )
    lines.append("  ]")
    return "\n".join(lines) + "\n"


def generation_id():
    # The timestamp sorts roots chronologically; the pid and a short token keep two updates in
    # the same second (or a retried one) from sharing a root directory.
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    return f"{stamp}-{os.getpid()}-{uuid.uuid4().hex[:4]}"


def store_link(path, store):
    """The store path a linkFarm entry points at; anything else is a broken build."""
    try:
        target = os.readlink(path)
    except OSError:
        raise UpdateError(f"the build left no output at {path}") from None
    prefix = store.as_posix().rstrip("/") + "/"
    if not target.startswith(prefix):
        raise UpdateError(f"{path} points at {target}, which is not in {store}")
    return target


def nix_build(context, snapshot, plugin_targets, skills, generation, console):
    """Build this generation and root it. Returns (variant paths, skills store path)."""
    expression = build_expression(context, snapshot, plugin_targets, skills)
    generation.mkdir(parents=True, exist_ok=True)
    link = generation / "build"
    command = [
        "nix",
        "build",
        "--impure",
        "--out-link",
        str(link),
        "--expr",
        expression,
        "--extra-experimental-features",
        "nix-command flakes",
    ]
    try:
        proc = subprocess.run(
            command, capture_output=True, text=True, check=False, env=context.environment
        )
    except FileNotFoundError:
        raise UpdateError("nix is not installed") from None
    if proc.returncode != 0:
        # The whole build log, so a pnpm or claude failure is visible here rather than in a log.
        for stream in (proc.stderr, proc.stdout):
            if stream.strip():
                console.err.write(stream if stream.endswith("\n") else stream + "\n")
        raise UpdateError("the snapshot build failed; the state in current.json is unchanged")

    built = {}
    for name, variant in plugin_targets:
        built[(name, variant)] = store_link(link / "plugins" / name / variant, context.store)
    skills_store = store_link(link / "skills", context.store) if skills else None
    if skills_store is not None:
        missing = [name for name in skills if not (Path(skills_store) / "skills" / name).is_dir()]
        if missing:
            raise UpdateError(f"the skills snapshot {skills_store} lacks {', '.join(missing)}")
    return built, skills_store


# --------------------------------------------------------------------------------------------
# Commands


def cmd_update(args, env, console):
    validate_names(args.names)
    if args.skill and args.harness:
        raise UpdateError("--harness filters plugin variants; skills have none")
    # Repeat a name and the linkFarm would get two entries called the same thing.
    names = list(dict.fromkeys(args.names))
    context = Context.from_env(env)
    baseline = load_baseline(context.baseline_path)

    with state_lock(context.state, context.lock_timeout):
        plugins, skills = load_state(context.state)
        temporary = Path(tempfile.mkdtemp(prefix=f"{PROG}-update-"))
        keep = bool(env.get("AGENTS_UPDATE_KEEP_SNAPSHOT"))
        planned, selected_skills, supported = [], [], {}
        built, skills_store = {}, None
        generation = None
        try:
            snapshot = publish_snapshot(
                context.checkout, temporary / "agents-snapshot", context.environment
            )
            for path in snapshot.skipped[:5]:
                console.warn(f"{PROG}: left out of the snapshot (submodule or deleted): {path}")
            planned, selected_skills, supported = plan_update(
                snapshot.root, names, args.skill, args.harness
            )

            if args.dry_run:
                console.say(
                    f"dry run: {describe_plan(planned, selected_skills)} from "
                    f"{short(snapshot.revision)} ({describe_tree(snapshot)})"
                )
                console.say("dry run: nothing built, state unchanged")
                return 0

            generation = context.state / "roots" / generation_id()
            try:
                built, skills_store = nix_build(
                    context, snapshot.root, planned, selected_skills, generation, console
                )
            except UpdateError:
                # Keep the published tree so a failed pnpm or claude run can be inspected.
                keep = True
                raise

            plugins = apply_plugins(plugins, baseline.revision, planned, supported, built, args.harness)
            skills = apply_skills(skills, baseline.revision, selected_skills, skills_store)
            save_state(context.state, plugins, skills)
        finally:
            if keep:
                console.warn(f"{PROG}: kept the published snapshot in {temporary}")
            else:
                shutil.rmtree(temporary, ignore_errors=True)

    console.say(
        f"published {describe_plan(planned, selected_skills)} from "
        f"{short(snapshot.revision)} ({describe_tree(snapshot)})"
    )
    for (name, variant), path in sorted(built.items()):
        console.say(f"  {name} {variant}: {path}")
    for name in sorted(selected_skills):
        console.say(f"  {name} skill: {Path(skills_store) / 'skills' / name}")
    console.say(f"state: {context.state / STATE_FILE} (baseline {short(baseline.revision)})")
    console.say(f"root: {generation / 'build'} (kept; older roots stay for running sessions)")

    if args.live:
        harnesses = HARNESSES if args.live == "all" else (args.live,)
        run_live(context.state, harnesses, console)
    return 0


def describe_plan(planned, skills):
    parts = [f"{name} {variant}" for name, variant in planned]
    if skills:
        parts.append("skills " + ", ".join(sorted(skills)))
    return ", ".join(parts) if parts else "nothing"


def describe_tree(snapshot):
    dirty = f"{snapshot.dirty} changed path{'s' if snapshot.dirty != 1 else ''}" if snapshot.dirty else "clean"
    return f"{snapshot.files} files, {dirty}"


def short(revision):
    return revision[:7] if revision else "unknown"


def apply_plugins(plugins, revision, planned, supported, built, harness):
    """Merge this build into the state; a variant that only inherits the baseline stays null."""
    updated = {name: dict(entry) for name, entry in plugins.items()}
    for name in {name for name, _ in planned}:
        previous = updated.get(name) or {}
        entry = {}
        for variant in HARNESSES:
            value = previous.get(variant)
            if (name, variant) in built:
                value = built[(name, variant)]
            elif (harness is None or harness == variant) and variant not in supported.get(name, ()):
                # The checkout no longer offers this half: stop overriding the baseline.
                value = None
            entry[variant] = value
        # A filtered update rewrote one half only, so restamping the entry would claim the
        # untouched half came from this baseline too and `check` would stop warning about it.
        # Leave the pin alone while the other half still holds an override.
        untouched_override = harness is not None and name in updated and any(
            previous.get(variant) for variant in HARNESSES if variant != harness
        )
        entry["baseline"] = previous.get("baseline") or revision if untouched_override else revision
        updated[name] = entry
    return updated


def apply_skills(skills, revision, selected, skills_store):
    updated = {name: dict(entry) for name, entry in skills.items()}
    for name in selected:
        updated[name] = {"path": f"{skills_store}/skills/{name}", "baseline": revision}
    return updated




def cmd_reset(args, env, console):
    validate_names(args.names)
    if args.skill and args.harness:
        raise UpdateError("--harness filters plugin variants; skills have none")
    state = state_dir(env)
    with state_lock(state, lock_timeout(env)):
        plugins, skills = load_state(state)
        changed = []
        names = list(dict.fromkeys(args.names))
        if args.skill:
            for name in names:
                if skills.pop(name, None) is not None:
                    changed.append(f"{name} (skill)")
        else:
            for name in names:
                entry = plugins.get(name)
                if entry is None:
                    continue
                if args.harness is None:
                    plugins.pop(name)
                    changed.append(name)
                elif entry.get(args.harness):
                    entry[args.harness] = None
                    if not any(entry.get(variant) for variant in HARNESSES):
                        plugins.pop(name)
                    changed.append(f"{name} ({args.harness})")
        if changed:
            save_state(state, plugins, skills)
            console.say(f"reset to the baseline: {', '.join(changed)}")
        else:
            console.say("nothing to reset: no snapshot for those names")
    return 0


def cmd_status(env, console):
    state = state_dir(env)
    console.say(f"{PROG} updates: {state}")
    baseline = None
    baseline_path = env.get("AGENTS_BASELINE")
    if baseline_path:
        try:
            baseline = load_baseline(baseline_path)
        except UpdateError as exc:
            console.warn(f"{PROG}: {exc}")
    console.say(f"baseline: {short(baseline.revision) if baseline else 'unknown (AGENTS_BASELINE not set)'}")

    try:
        plugins, skills = load_state(state)
    except UpdateError as exc:
        console.warn(f"{PROG}: {exc}")
        plugins, skills = {}, {}

    console.say(f"plugins ({len(plugins)}):")
    for name in sorted(plugins):
        entry = plugins[name]
        parts = [
            f"{variant} {entry.get(variant) or 'baseline'}" for variant in HARNESSES
        ]
        console.say(f"  {name}: {', '.join(parts)} (pinned {short(entry.get('baseline', ''))})")
    if not plugins:
        console.say("  none")
    console.say(f"skills ({len(skills)}):")
    for name in sorted(skills):
        entry = skills[name]
        console.say(f"  {name}: {entry['path']} (pinned {short(entry.get('baseline', ''))})")
    if not skills:
        console.say("  none")

    sessions = load_sessions(state)
    if sessions:
        console.say(f"sessions ({len(sessions)}):")
        for session in sessions:
            console.say(f"  {session.describe()}")
    return 0


def cmd_check(env, console):
    """Non-blocking drift report: one line per problem, nothing when all is well, always 0."""
    state = state_dir(env)
    problems = []
    try:
        plugins, skills = load_state(state)
    except UpdateError as exc:
        problems.append(str(exc))
        plugins, skills = {}, {}

    baseline = None
    baseline_path = env.get("AGENTS_BASELINE")
    if not baseline_path:
        problems.append(
            "AGENTS_BASELINE is not set, so published snapshots cannot be compared with the pin"
        )
    else:
        try:
            baseline = load_baseline(baseline_path)
        except UpdateError as exc:
            problems.append(str(exc))

    for name, entry in sorted(plugins.items()):
        pinned = entry.get("baseline") or ""
        if baseline is not None and pinned != baseline.revision:
            problems.append(
                f"{name} was published from {short(pinned)}, the pinned baseline is "
                f"{short(baseline.revision)}; run `{PROG} update {name}`"
            )
        for variant in HARNESSES:
            path = entry.get(variant)
            if path and not Path(path).exists():
                problems.append(
                    f"the {variant} snapshot for {name} is gone from the store; "
                    f"run `{PROG} update {name}`"
                )
    for name, entry in sorted(skills.items()):
        pinned = entry.get("baseline") or ""
        if baseline is not None and pinned != baseline.revision:
            problems.append(
                f"the {name} skill was published from {short(pinned)}, the pinned baseline is "
                f"{short(baseline.revision)}; run `{PROG} update {name} --skill`"
            )
        if not Path(entry["path"]).exists():
            problems.append(
                f"the {name} skill snapshot is gone from the store; "
                f"run `{PROG} update {name} --skill`"
            )

    for session in load_sessions(state):
        # Only a session that is still running can act on this: a dead session's failed ack
        # (or a request the bridge rejected while it was alive) would otherwise warn forever.
        if session.process != "alive":
            continue
        ack = session.ack()
        if ack and ack.get("status") == "failed":
            problems.append(
                f"session {session.session_id}'s last reload failed: {ack.get('message') or 'no message'}"
            )

    for problem in problems:
        console.say(f"{PROG} updates: {problem}")
    return 0


def cmd_resolve(env, console):
    baseline_path = env.get("AGENTS_BASELINE")
    if not baseline_path:
        raise UpdateError("AGENTS_BASELINE is not set, so there is nothing to resolve")
    baseline = load_baseline(baseline_path)
    try:
        plugins, skills = load_state(state_dir(env))
    except UpdateError as exc:
        # A launch must not fail over a corrupt state file; the pinned baseline still loads.
        console.warn(f"{PROG}: {exc}; resolving the baseline only")
        plugins, skills = {}, {}
    json.dump(effective(baseline, plugins, skills), console.out, sort_keys=False)
    console.out.write("\n")
    console.out.flush()
    return 0


# --------------------------------------------------------------------------------------------
# Live reload
#
# There is no reload API in either harness that another process can call. pi sessions
# register themselves (pid, status, requestPath) in <state>/sessions; the bridge inside a
# session polls its request file, re-resolves via `agents resolve`, and writes an ack. This
# CLI only delivers requests and reports what the ack says: without an ack it says
# "requested", never "reloaded". Claude Code resolves plugin paths at launch, so it has no
# bridge at all and the only honest answer is "restart the session".


@dataclass
class Session:
    file: Path
    data: dict
    process: str  # alive | missing | foreign | unreadable

    @property
    def harness(self):
        return self.data.get("harness")

    @property
    def session_id(self):
        value = self.data.get("sessionId")
        return value if isinstance(value, str) else self.file.stem

    @property
    def status(self):
        value = self.data.get("status")
        return value if isinstance(value, str) else "busy"

    @property
    def request_path(self):
        value = self.data.get("requestPath")
        return Path(value) if isinstance(value, str) and value else None

    def ack(self):
        path = self.request_path
        return read_json(Path(str(path) + ".ack")) if path else None

    def describe(self):
        note = "" if self.process == "alive" else f" ({self.process})"
        # The last answer the bridge gave, which belongs to the request it answered: status
        # lists it as history, never as a result for whatever is pending now.
        ack = self.ack()
        status = ack.get("status") if ack else None
        answered = f" last ack {status}" if isinstance(status, str) else ""
        return f"{self.harness or 'unknown'} {self.session_id} {self.status}{note}{answered}"


def read_json(path):
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def load_sessions(state):
    directory = Path(state) / "sessions"
    sessions = []
    if not directory.is_dir():
        return sessions
    for path in sorted(directory.glob("*.json")):
        data = read_json(path)
        if data is None:
            sessions.append(Session(file=path, data={}, process="unreadable"))
            continue
        sessions.append(Session(file=path, data=data, process=process_state(data.get("pid"))))
    return sessions


def process_state(pid):
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return "missing"
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return "missing"
    except PermissionError:
        return "foreign"
    except OSError:
        return "missing"
    owner = process_owner(pid)
    if owner is None:
        return "alive"
    return "alive" if owner == os.geteuid() else "foreign"


def process_owner(pid):
    try:
        with open(f"/proc/{pid}/status", encoding="utf-8", errors="replace") as stream:
            for line in stream:
                if line.startswith("Uid:"):
                    return int(line.split()[1])
    except (OSError, ValueError, IndexError):
        return None
    return None


def deliver(session, ttl=REQUEST_TTL):
    """Ask `session` to reload *now*.

    Returns (outcome, detail) with outcome error|pending|written.

    A request always goes out for the update that just happened: an ack on a request that is
    still lying around answers an *earlier* update, so it is reported as history
    (`detail["previous_ack"]`) and the file is replaced. The exception is a request the
    bridge has not answered and has not removed — that is an update still in flight, and
    overwriting it would make the session reload twice or report the wrong one.
    """
    path = session.request_path
    if path is None:
        return "error", "the session file has no requestPath"
    previous = read_json(path)
    ack = session.ack()
    previous_ack = None
    if previous is None:
        # No request on disk: the bridge claimed it (and normally removes it), so whatever
        # the ack file says belongs to an earlier update. Report it as history and deliver.
        previous_ack = ack
    elif ack and ack.get("id") == previous.get("id"):
        # Answered but not cleaned up: consume the answer, then deliver this update's request.
        previous_ack = ack
    else:
        try:
            age = time.time() - path.stat().st_mtime
        except OSError:
            age = ttl
        if age < ttl:
            return "pending", {"request": previous, "previous_ack": ack}
    request = {"id": uuid.uuid4().hex, "requestedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    try:
        write_json_atomic(path, request)
    except OSError as exc:
        return "error", f"cannot write {path}: {exc.strerror or exc}"
    return "written", {"request": request, "previous_ack": previous_ack}


def run_live(state, harnesses, console):
    """Best effort: deliver requests, report exactly what is known and nothing more."""
    sessions = load_sessions(state)
    for harness in harnesses:
        if harness == "claude":
            console.say(
                "live claude: unsupported; restart the session "
                "(Claude Code resolves plugin paths at launch)"
            )
            continue
        group = [session for session in sessions if session.harness == "pi"]
        usable = [session for session in group if session.process == "alive"]
        if len(usable) < len(group):
            console.say(f"live pi: ignored {len(group) - len(usable)} stale session file(s)")
        if not usable:
            console.say("live pi: no running pi session with an update bridge; restart older sessions to enable it")
            continue
        for session in usable:
            outcome, detail = deliver(session)
            if outcome == "pending":
                console.say(f"live pi: {session.session_id} has an unanswered request; not queued again")
            elif outcome == "written":
                # Never report an older update's answer as this one's result.
                report_ack(console, session, detail.get("previous_ack"), "previous request")
                # The bridge handles a request whenever the session is next free; "busy" only
                # means the human is mid-turn, so say what we know: it is queued, not applied.
                verb = "requested" if session.status == "idle" else "queued"
                console.say(f"live pi: {verb} in {session.session_id} ({session.status}); not confirmed")
            else:
                console.say(f"live pi: {detail}")


def report_ack(console, session, ack, what):
    """Say what an ack claims, for the update it belongs to and no other."""
    if not ack:
        return
    status = ack.get("status")
    if status == "applied":
        console.say(f"live pi: {session.session_id}'s {what} was applied")
    elif status == "failed":
        console.say(
            f"live pi: {session.session_id}'s {what} failed: {ack.get('message') or 'no message'}"
        )
    else:
        console.say(f"live pi: {session.session_id}'s {what} answered {status!r}")


# --------------------------------------------------------------------------------------------
# Entry point


def parser():
    main_parser = argparse.ArgumentParser(
        prog=PROG,
        description="Publish the agents checkout's plugins and skills as immutable snapshots.",
        epilog=(
            "state: $XDG_STATE_HOME/agents-updates/current.json; harnesses read the effective "
            "paths with `agents resolve`"
        ),
    )
    commands = main_parser.add_subparsers(dest="command", required=True, metavar="COMMAND")

    update = commands.add_parser(
        "update", help="snapshot plugins or skills from the checkout's working tree"
    )
    update.add_argument("names", nargs="+", metavar="NAME")
    update.add_argument("--skill", action="store_true", help="NAMEs are skills, not plugins")
    update.add_argument("--harness", choices=HARNESSES, help="only this half of each plugin")
    update.add_argument("--live", choices=LIVE_CHOICES, help="ask running sessions to reload (best effort)")
    update.add_argument("--dry-run", action="store_true", help="show what would be published")

    reset = commands.add_parser("reset", help="drop snapshots so the pinned baseline applies again")
    reset.add_argument("names", nargs="+", metavar="NAME")
    reset.add_argument("--skill", action="store_true", help="NAMEs are skills, not plugins")
    reset.add_argument("--harness", choices=HARNESSES, help="only this half of each plugin")

    commands.add_parser("status", help="show the snapshots and live session files")
    commands.add_parser("check", help="warn about drift; always exits 0")
    commands.add_parser("resolve", help="print the effective plugin and skill paths as JSON")
    return main_parser


def main(argv=None, env=None, out=None, err=None):
    args = parser().parse_args(sys.argv[1:] if argv is None else argv)
    console = Console(out, err)
    environment = dict(os.environ) if env is None else dict(env)
    try:
        if args.command == "update":
            return cmd_update(args, environment, console)
        if args.command == "reset":
            return cmd_reset(args, environment, console)
        if args.command == "status":
            return cmd_status(environment, console)
        if args.command == "check":
            return cmd_check(environment, console)
        if args.command == "resolve":
            return cmd_resolve(environment, console)
        raise UpdateError(f"unknown command {args.command}")
    except UpdateError as exc:
        console.warn(f"{PROG}: {exc}")
        return 1
    except OSError as exc:
        console.warn(f"{PROG}: {exc.strerror or exc}")
        return 1
    except KeyboardInterrupt:
        console.warn(f"{PROG}: interrupted")
        return 130


if __name__ == "__main__":
    sys.exit(main())
