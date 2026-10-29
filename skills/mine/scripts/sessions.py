#!/usr/bin/env python3
"""Read Claude Code and pi transcripts as runs of one skill, tool or command.

Sources: ~/.claude/projects and ~/.claude-work/projects (top-level sessions; subagent
transcripts too with --subagents, .zst through the `zstd` CLI), and
~/.pi/agent/sessions. `claude -p` sessions and pi subagent sessions are skipped,
sidechains dropped, and a session stored twice (a resume, a fork, a worktree slug)
counts once. Sessions that ran /mine are never runs, so mining doesn't count itself.

  runs MATCHER... [--since DATE] [--repo DIR] [--json] [--show IDS|all] [--max-lines N]
      A signal header, then one line per run. --show prints the named runs condensed:
      numbered typed turns, question answers, each turn's last assistant text, tool
      calls with their errors and denials. A skill run spans from its invocation, plus
      the skills it loads before you speak again, to the prompt that invokes another
      skill or the session's end, so it can include work done after the skill's part.
      Any other target's run is one session's matches.
  work --path SUBSTR... [--mention REGEX] [--limit N]
      Sessions that edited a matching file or mention REGEX in a typed turn, newest
      first, as your typed turns only.
  session ID|latest [--cwd DIR]
      One whole session condensed; `latest` is the newest one that ran in DIR.
  prompts [--since DATE] [--source S] [--cwd SUBSTR] [--grep REGEX] [--json]
      The first typed prompt of every session.

MATCHER is any of --skill NAME, --tool NAME, --cmd PREFIX, --text REGEX, each
repeatable; a run matches if any does. --skill counts typed and model invocations and
plugin-prefixed copies (`skills:NAME`); the copy that ran is the `body` path. A Claude
Skill call counts as typed when the prompt before it names `/NAME`.

Answer classes: recommended, other (another option when one was recommended), no-rec
(an option when none was), custom (your own text), multi. Denials are Claude's only;
pi records none.
"""

import argparse
import difflib
import glob
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime

HOME = os.path.expanduser("~")
CLAUDE_ROOTS = [("claude", f"{HOME}/.claude/projects"), ("claude-work", f"{HOME}/.claude-work/projects")]
PI_ROOT = f"{HOME}/.pi/agent/sessions"

# Harness-injected text that arrives as a user turn in logs predating `origin`.
CLAUDE_NOISE = (
    "Another Claude",
    "This session is being continued",
    "The summarized",
    "Caveat:",
    "[Image",
    "<local-command-",
    "<bash-stdout",
    "<bash-stderr",
    "<task-notification",
    "<system-reminder",
    "<artifact-",
)
# Harness commands that change settings or the view, never a request to the agent.
LOCAL_COMMANDS = {
    "agents", "artifacts", "clear", "compact", "config", "context", "cost", "doctor", "effort", "exit", "fast",
    "help", "hooks", "ide", "list-agents", "login", "logout", "mcp", "memory", "model", "open", "permissions",
    "plugin", "reload-plugins", "reload-skills", "remote-control", "rename", "resume", "status", "usage",
}  # fmt: skip
# A pi session whose first user turn starts like this is a subagent's brief.
PI_SUBAGENT = ("You are ", "CONTEXT for")
EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit", "edit", "write"}
BASH_TOOLS = {"Bash", "bash"}
WIDTH = {"prompt": 1500, "say": 1200, "result": 240}

_warned_zstd = False


def lines_of(path):
    global _warned_zstd
    if path.endswith(".zst"):
        if not shutil.which("zstd"):
            if not _warned_zstd:
                print("sessions: zstd not on PATH, skipping compressed transcripts", file=sys.stderr)
                _warned_zstd = True
            return []
        out = subprocess.run(["zstd", "-dcq", path], capture_output=True, text=True, errors="replace")
        return out.stdout.splitlines()
    with open(path, errors="replace") as f:
        return f.readlines()


def records(path):
    for line in lines_of(path):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if isinstance(r, dict):
            yield r


def text_of(content):
    if isinstance(content, str):
        return content
    return "\n".join(b.get("text", "") for b in content or () if isinstance(b, dict) and b.get("type") == "text")


def clip(text, width):
    text = " ".join(str(text).split())
    return text if len(text) <= width else text[: width - 1] + "…"


def tilde(path):
    return (path or "?").replace(HOME, "~", 1)


def option_labels(q):
    return [o.get("label") if isinstance(o, dict) else str(o) for o in q.get("options") or ()]


def answer_class(label, options, kind=None, multi=False):
    if multi or kind == "multi":
        return "multi"
    if kind == "custom" or (options and label not in options):
        return "custom"
    if "(Recommended)" in label:
        return "recommended"
    if options and not any("(Recommended)" in o for o in options):
        return "no-rec"
    return "other"


# ---------------------------------------------------------------------------
# Parsing: every session becomes a list of events, the same shape for both harnesses.


class Session:
    def __init__(self, source, path):
        self.source = source
        self.path = path
        self.id = os.path.basename(path).split(".")[0]
        self.cwd = None
        self.cwds = set()
        self.started = None
        self.events = []
        self.ids = set()
        self.offered = set()
        self.parent = None
        self.skip = False

    def add(self, kind, ts, **fields):
        last = self.events[-1] if self.events else None
        # A prompt edited before it was sent is logged again in full: keep the last.
        if kind == "prompt" and last and last["kind"] == "prompt" and fields["text"].startswith(last["text"].rstrip(". ")):
            self.events.pop()
        self.events.append({"kind": kind, "ts": ts, **fields})

    def last_prompt(self):
        return next((e["text"] for e in reversed(self.events) if e["kind"] == "prompt"), "")


def render_slash(text):
    name = re.search(r"<command-name>(.*?)</command-name>", text, re.S)
    args = re.search(r"<command-args>(.*?)</command-args>", text, re.S)
    return (name.group(1).strip() if name else ""), (args.group(1).strip() if args else "")


def parse_claude(source, path, sidechains=False):
    s = Session(source, path)
    for r in records(path):
        if r.get("isSidechain") and not sidechains:
            continue
        ts, rid = r.get("timestamp"), r.get("uuid")
        if r.get("cwd"):
            s.cwd = s.cwd or r["cwd"]
            s.cwds.add(r["cwd"])
        s.started = s.started or ts
        if r.get("entrypoint") == "sdk-cli":
            s.skip = True
        content = (r.get("message") or {}).get("content")
        if r.get("type") == "assistant":
            for b in content or ():
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "text" and b.get("text", "").strip():
                    s.add("say", ts, id=rid, text=b["text"])
                elif b.get("type") == "tool_use":
                    inp = b.get("input") or {}
                    s.add("call", ts, id=rid, call_id=b.get("id"), name=b.get("name"), input=inp)
                    if b.get("name") == "Skill":
                        name = inp.get("skill", "")
                        asked = re.search(rf"(^|\s)/{re.escape(name.split(':')[-1])}\b", s.last_prompt())
                        s.add("skill", ts, id=rid, name=name, args=inp.get("args", ""), via="typed" if asked else "model")
            continue
        if r.get("type") != "user":
            continue
        text = text_of(content)
        if r.get("isMeta"):
            m = re.match(r"Base directory for this skill: (\S+)\n", text)
            if m:
                s.add("body", ts, id=rid, path=m.group(1), text=text)
            continue
        if isinstance(content, list):
            for b in content:
                if isinstance(b, dict) and b.get("type") == "tool_result":
                    out = b.get("content")
                    s.add(
                        "result",
                        ts,
                        id=rid,
                        call_id=b.get("tool_use_id"),
                        error=bool(b.get("is_error")),
                        denial=r.get("toolDenialKind"),
                        text=out if isinstance(out, str) else text_of(out),
                    )
        tur = r.get("toolUseResult")
        if isinstance(tur, dict) and isinstance(tur.get("answers"), dict):
            notes = tur.get("annotations") or {}
            answers = []
            for q in tur.get("questions") or ():
                label = tur["answers"].get(q.get("question"))
                if label is None:
                    continue
                multi = bool(q.get("multiSelect")) or isinstance(label, list)
                label = ", ".join(map(str, label)) if isinstance(label, list) else str(label)
                note = (notes.get(q.get("question")) or {}).get("notes")
                answers.append(
                    {"header": q.get("header"), "question": q.get("question"), "answer": label, "class": answer_class(label, option_labels(q), multi=multi), "note": note}
                )
            s.add("answer", ts, id=rid, answers=answers)
        text = re.sub(r"^(\s*<system-reminder>.*?</system-reminder>)+", "", text, flags=re.S).strip()
        if not text:
            continue
        if text.startswith("[Request interrupted"):
            s.add("interrupt", ts, id=rid)
            continue
        origin = r.get("origin")
        if origin is not None and origin.get("kind") != "human":
            continue
        if text.startswith("<bash-input>"):
            s.add("prompt", ts, id=rid, text="!" + re.sub(r"</?bash-input>", "", text).strip())
        elif "<command-name>" in text[:200]:
            name, args = render_slash(text)
            if name and name.lstrip("/") not in LOCAL_COMMANDS:
                s.add("prompt", ts, id=rid, text=f"{name} {args}".strip(), slash=name.lstrip("/"))
        elif re.fullmatch(r"/([\w-]+)\b.*", text) and text[1:].split()[0] in LOCAL_COMMANDS:
            continue
        elif origin is not None or not text.startswith(CLAUDE_NOISE):
            s.add("prompt", ts, id=rid, text=text)
    # A typed /name is a skill run when the harness injected that skill's body next.
    for i, e in enumerate(s.events):
        if e["kind"] == "prompt" and e.get("slash"):
            for nxt in s.events[i + 1 : i + 4]:
                if nxt["kind"] == "body" and nxt["path"].rstrip("/").endswith("/" + e["slash"].split(":")[-1]):
                    args = e["text"].split(" ", 1)[1] if " " in e["text"] else ""
                    s.events.insert(i + 1, {"kind": "skill", "ts": e["ts"], "id": e["id"], "name": e["slash"], "args": args, "via": "typed"})
                    break
    s.ids = {e["id"] for e in s.events if e.get("id")}
    return s


CODEMODE_CALL = re.compile(r"\btools\.(\w+)\s*\(")
CODEMODE_COMMAND = re.compile(r"""^\s*\{[^}]*?\bcommand\s*:\s*(["'`])(.*?)(?<!\\)\1""", re.S)


def parse_pi(path):
    s = Session("pi", path)
    calls = {}  # toolCall id → arguments
    skill_reads = {}  # toolCall id → skill dir, for a model-invoked skill's body
    first_user = True
    for r in records(path):
        ts = r.get("timestamp")
        if r.get("type") == "session":
            s.cwd, s.started, s.id, s.parent = r.get("cwd"), ts, r.get("id") or s.id, r.get("parentSession")
            s.cwds.add(s.cwd)
            continue
        if r.get("id"):
            s.ids.add(r["id"])
        if r.get("type") != "message":
            continue
        m = r.get("message") or {}
        role, rid = m.get("role"), r.get("id")
        if role == "system":
            tools = (m.get("sections") or {}).get("tools") or ""
            s.offered |= set(re.findall(r"^- (\w+):", tools, re.M))
        elif role == "user":
            text = text_of(m.get("content")).strip()
            if not text:
                continue
            if first_user and text.startswith(PI_SUBAGENT):
                s.skip = True
            first_user = False
            sk = re.match(r'<skill name="([^"]+)" location="([^"]+)">\n?(.*?)</skill>\s*(.*)', text, re.S)
            if sk:
                name, loc, body, args = sk.groups()
                s.add("prompt", ts, id=rid, text=f"/skill:{name} {args}".strip(), slash=name)
                s.add("skill", ts, id=rid, name=name, args=args, via="typed")
                s.add("body", ts, id=rid, path=os.path.dirname(loc), text=body)
            else:
                s.add("prompt", ts, id=rid, text=text)
        elif role == "assistant":
            for b in m.get("content") or ():
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "text" and b.get("text", "").strip():
                    s.add("say", ts, id=rid, text=b["text"])
                elif b.get("type") == "toolCall":
                    args = b.get("arguments") or {}
                    calls[b.get("id")] = args
                    s.add("call", ts, id=rid, call_id=b.get("id"), name=b.get("name"), input=args)
                    if b.get("name") == "codemode":
                        # Inner calls share the codemode call's result, so its errors count for them.
                        code = args.get("code", "")
                        for m_ in CODEMODE_CALL.finditer(code):
                            inner = {"via": "codemode"}
                            cmd = CODEMODE_COMMAND.match(code, m_.end()) if m_.group(1) == "bash" else None
                            if cmd:
                                inner["command"] = cmd.group(2)
                            s.add("call", ts, id=rid, call_id=b.get("id"), name=m_.group(1), input=inner)
                    # pi has no Skill tool: a model-invoked skill is a read of an installed
                    # SKILL.md. One inside the session's own tree is someone editing it.
                    target = str(args.get("path", ""))
                    sk = re.search(r"/([\w:-]+)/SKILL\.md$", target)
                    if b.get("name") == "read" and sk and not (s.cwd and target.startswith(s.cwd.rstrip("/") + "/")):
                        s.add("skill", ts, id=rid, name=sk.group(1), args="", via="model")
                        skill_reads[b.get("id")] = os.path.dirname(target)
            if m.get("stopReason") == "aborted":
                s.add("interrupt", ts, id=rid)
        elif role == "toolResult":
            s.add("result", ts, id=rid, call_id=m.get("toolCallId"), error=bool(m.get("isError")), denial=None, text=text_of(m.get("content")))
            if m.get("toolCallId") in skill_reads and not m.get("isError"):
                s.add("body", ts, id=rid, path=skill_reads[m.get("toolCallId")], text=text_of(m.get("content")))
            details = m.get("details") or {}
            if m.get("toolName") == "ask_user_question" and details.get("answers"):
                asked = (calls.get(m.get("toolCallId")) or {}).get("questions") or []
                answers = []
                for a in details["answers"]:
                    idx = a.get("questionIndex", 0)
                    q = asked[idx] if isinstance(idx, int) and idx < len(asked) else {}
                    values = a.get("values") or []
                    label = a.get("answer") or ", ".join(map(str, values))
                    multi = a.get("kind") == "multi" or len(values) > 1
                    answers.append(
                        {
                            "header": q.get("header") or a.get("header"),
                            "question": a.get("question") or q.get("question"),
                            "answer": label,
                            "class": answer_class(label, option_labels(q), a.get("kind"), multi),
                            "note": a.get("notes") or a.get("note"),
                        }
                    )
                s.add("answer", ts, id=rid, answers=answers)
    return s


_entry_ids = {}


def entry_ids(path):
    """The entry ids of a pi session file, cached; a fork copies its parent's, a subagent shares none."""
    if path not in _entry_ids:
        try:
            _entry_ids[path] = {r["id"] for r in records(path) if r.get("id") and r.get("type") != "session"}
        except OSError:
            _entry_ids[path] = None
    return _entry_ids[path]


def all_sessions(prefilter=None, subagents=False):
    """Every session worth reading, deduplicated. `prefilter` is a regex the raw file must match."""
    paths = []
    for source, root in CLAUDE_ROOTS:
        paths += [(source, p, False) for p in glob.glob(f"{root}/*/*.jsonl")]
        if subagents:
            paths += [(source, p, True) for p in glob.glob(f"{root}/*/*/subagents/**/*.jsonl*", recursive=True)]
    paths += [("pi", p, False) for p in glob.glob(f"{PI_ROOT}/*/*.jsonl")]
    best = {}
    for source, path, sidechains in paths:
        if prefilter is not None:
            raw = "\n".join(lines_of(path)) if path.endswith(".zst") else open(path, errors="replace").read()
            if not prefilter.search(raw):
                continue
        s = parse_pi(path) if source == "pi" else parse_claude(source, path, sidechains)
        if s.skip or not s.events:
            continue
        if s.parent:
            parent = entry_ids(s.parent)
            if parent is not None and not (parent & s.ids):
                continue  # a pi subagent: its brief is another agent's, not a typed prompt
        # A resume or fork repeats its origin's records, so the first one names the session.
        key = (source, s.events[0].get("id") or s.id)
        if key not in best or len(s.events) > len(best[key].events):
            best[key] = s
    return sorted(best.values(), key=lambda s: s.started or "")


# ---------------------------------------------------------------------------
# Matching and runs.


def command_heads(command):
    for part in re.split(r"&&|\|\||[;|\n]", command or ""):
        words = part.split()
        while words and re.match(r"^\w+=", words[0]):
            words.pop(0)
        if words:
            yield " ".join(words)


class Matcher:
    def __init__(self, args):
        self.skills = args.skill or []
        self.tools = args.tool or []
        self.cmds = args.cmd or []
        self.texts = [re.compile(t, re.I) for t in args.text or []]

    def prefilter(self):
        parts = []
        for n in self.skills:
            e = re.escape(n)
            parts += [rf'"skill":"(?:[\w-]+:)?{e}"', rf"<command-name>/(?:[\w-]+:)?{e}<", rf'<skill name=\\"{e}\\"', rf"/{e}/SKILL\.md"]
        parts += [re.escape(n) for n in self.tools + self.cmds]
        parts += [t.pattern for t in self.texts]
        return re.compile("|".join(parts), re.I) if parts else None

    def skill_hit(self, e):
        return e["kind"] == "skill" and any(e["name"] == n or e["name"].endswith(":" + n) for n in self.skills)

    def other_hit(self, e):
        if e["kind"] == "call":
            name = e["name"] or ""
            if any(name == n or name.endswith("__" + n) for n in self.tools):
                return True
            if name in BASH_TOOLS and any(h == p or h.startswith(p + " ") for p in self.cmds for h in command_heads(e["input"].get("command"))):
                return True
        if self.texts:
            blob = e.get("text") or json.dumps(e.get("input") or "")
            return any(t.search(blob) for t in self.texts)
        return False


def bare(name):
    return name.split(":")[-1]


def find_runs(sessions, matcher, since=None):
    runs = []
    for s in sessions:
        ev = s.events
        skills = [i for i, e in enumerate(ev) if e["kind"] == "skill"]
        if any(bare(ev[i]["name"]) == "mine" for i in skills):
            continue
        prompts = [i for i, e in enumerate(ev) if e["kind"] == "prompt"]
        # A model re-reading the skill that is already open continues its run.
        starts, open_skill = [], None
        for i in skills:
            if matcher.skill_hit(ev[i]) and not (ev[i]["via"] == "model" and ev[i]["name"] == open_skill):
                starts.append(i)
            open_skill = ev[i]["name"]
        for n, i in enumerate(starts):
            # Skills it loads before you speak again (grill-me loading grilling) are part
            # of the run, even when reloaded later; any other skill ends it at the prompt
            # that asked for it.
            opening = next((p for p in prompts if p > i), len(ev))
            family = {ev[j]["name"] for j in skills if i <= j < opening}
            nxt = next((j for j in skills if j >= opening and (j in starts or ev[j]["name"] not in family)), None)
            end = len(ev)
            if nxt is not None:
                end = max([p for p in prompts if opening <= p <= nxt], default=nxt)
            runs.append(make_run(s, n, ev[i:end], ev[end:], ev[i]))
        hits = [] if starts else [e for e in ev if matcher.other_hit(e)]
        if hits:
            runs.append(make_run(s, 0, ev, [], hits[0], hits=hits))
    runs = [r for r in runs if not since or (r["ts"] or "") >= since]
    seen = {}
    for r in runs:  # a forked or resumed session repeats the invocation record
        key = (r["source"], r["start_id"], r["target"])
        if key not in seen or r["length"] > seen[key]["length"]:
            seen[key] = r
    return sorted(seen.values(), key=lambda r: r["ts"] or "")


def make_run(s, n, window, rest, start, hits=None):
    target = start.get("name") if start["kind"] == "skill" else None
    bodies = [e for e in window if e["kind"] == "body"]
    body = next((e for e in bodies if target and e["path"].rstrip("/").endswith("/" + bare(target))), bodies[0] if bodies else None)
    answers = [a for e in window if e["kind"] == "answer" for a in e["answers"]]
    results = [e for e in window if e["kind"] == "result"]
    if hits is not None:  # a tool or command: only its own calls' outcomes are signal
        ids = {h["call_id"] for h in hits if h["call_id"]}
        answers, results = [], [e for e in results if e["call_id"] in ids]
    denials = {}
    for e in results:
        if e["denial"]:
            denials[e["denial"]] = denials.get(e["denial"], 0) + 1
    return {
        "id": f"{s.id[-8:]}.{n}",  # pi ids are UUIDv7, so their heads are timestamps
        "source": s.source,
        "session": s.id,
        "path": s.path,
        "ts": start["ts"],
        "cwd": s.cwd,
        "start_id": start.get("id"),
        "length": len(window),
        "target": target,
        "via": start.get("via"),
        "args": start.get("args"),
        "body": body,
        "turns": sum(e["kind"] == "prompt" for e in window),
        "answers": answers,
        "interrupts": 0 if hits is not None else sum(e["kind"] == "interrupt" for e in window),
        "calls": len(hits) if hits is not None else None,
        "errors": sum(e["error"] for e in results),
        "denials": denials,
        "ended": "next-skill" if rest else "session-end",
        "after": next((e["text"] for e in rest if e["kind"] == "prompt"), None),
        "window": window,
        "hits": hits,
        "session_obj": s,
    }


# ---------------------------------------------------------------------------
# Versions: match the injected body against the repo's history of SKILL.md.


def body_text(text, args=""):
    """The comparable part of a skill body: no harness header, frontmatter, arguments or read footer."""
    text = re.sub(r"^(Base directory for this skill|References are relative to)[^\n]*\n", "", text.strip())
    text = re.split(r"\n\s*ARGUMENTS:", text)[0]
    text = re.sub(r"^---\n.*?\n---\n", "", text, flags=re.S)
    text = re.sub(r"\n*\[\d+ more lines in file\..*$", "", text, flags=re.S)
    # Claude substitutes $ARGUMENTS and named $args into the body; drop both sides' copy.
    if len(args or "") >= 4:
        text = text.replace(args, "")
    text = re.sub(r"\$\w+", "", text)
    return " ".join(text.split())


def repo_versions(repo, names):
    """[(label, body text)] oldest first, for every committed SKILL.md of the named skills."""
    versions = []
    if not repo:
        return versions
    for name in names:
        rel = f"skills/{bare(name)}/SKILL.md"
        # `--follow` ignores `--reverse`, so reverse here.
        log = subprocess.run(
            ["git", "-C", repo, "log", "--follow", "--name-only", "--format=@%h %cs", "--", rel],
            capture_output=True,
            text=True,
        ).stdout
        for commit, path in reversed(re.findall(r"^@(.+)\n\n(.+)$", log, re.M)):
            blob = subprocess.run(["git", "-C", repo, "show", f"{commit.split()[0]}:{path}"], capture_output=True, text=True)
            if blob.returncode == 0:
                versions.append((commit, body_text(blob.stdout)))
        if os.path.exists(os.path.join(repo, rel)):
            with open(os.path.join(repo, rel)) as f:
                versions.append(("uncommitted", body_text(f.read())))
    return versions


_version_cache = {}


def version_of(run, versions):
    """The commit that introduced the body that ran; `~` marks a near match, e.g. a truncated read."""
    if not run["body"]:
        return "?"
    text = body_text(run["body"]["text"], run["args"])
    if text not in _version_cache:
        label = next((lab for lab, v in versions if v == text), None)
        if label is None and len(text) > 200:
            label = next((f"~{lab}" for lab, v in versions if v.startswith(text)), None)
        if label is None and versions:
            ratio, lab = max((difflib.SequenceMatcher(None, text, v, autojunk=False).ratio(), lab) for lab, v in versions)
            label = f"~{lab}" if ratio >= 0.97 else "unmatched"
        _version_cache[text] = label or "unmatched"
    return _version_cache[text]


# ---------------------------------------------------------------------------
# Output.

CLASSES = ("recommended", "other", "no-rec", "custom", "multi")


def fmt_ts(ts):
    if not ts:
        return "?"
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone().strftime("%Y-%m-%d %H:%M")
    except ValueError:
        return ts[:16]


def header(runs, matcher, sessions, since):
    print(f"# {len(runs)} runs across {len({r['session'] for r in runs})} sessions")
    by_source = {}
    for r in runs:
        by_source[r["source"]] = by_source.get(r["source"], 0) + 1
    print("sources: " + ", ".join(f"{k} {v}" for k, v in sorted(by_source.items())))
    answers = [a for r in runs for a in r["answers"]]
    if answers:
        print(f"answers: {len(answers)} — " + ", ".join(f"{k} {sum(a['class'] == k for a in answers)}" for k in CLASSES))
        per = {}
        for a in answers:
            per.setdefault(a["header"] or clip(a["question"] or "?", 40), []).append(a["class"])
        recurring = {h: cls for h, cls in per.items() if len(cls) >= 3}
        print(f"question headers seen 3+ times: {len(recurring)} of {len(per)} ({'/'.join(CLASSES)})")
        for h, cls in sorted(recurring.items(), key=lambda kv: -len(kv[1])):
            print(f"  {h}: {'/'.join(str(cls.count(k)) for k in CLASSES)}")
    notes = sum(1 for a in answers if a["note"])
    calls = sum(r["calls"] or 0 for r in runs)
    print(f"interrupts: {sum(r['interrupts'] for r in runs)}, matched calls: {calls}, their errors: {sum(r['errors'] for r in runs)}, notes on answers: {notes}")
    denials = {}
    for r in runs:
        for k, v in r["denials"].items():
            denials[k] = denials.get(k, 0) + v
    if denials:
        print("denials: " + ", ".join(f"{k} {v}" for k, v in sorted(denials.items())))
    if matcher.tools:
        pi = [s for s in sessions if s.source == "pi" and (not since or (s.started or "") >= since)]
        offered = sum(bool(set(matcher.tools) & s.offered) for s in pi)
        called = len({r["session"] for r in runs if r["source"] == "pi"})
        print(f"pi sessions offering it: {offered}, calling it: {called}")


def run_line(r, versions):
    a = r["answers"]
    q = "q " + "/".join(str(sum(x["class"] == k for x in a)) for k in CLASSES) if a else "q -"
    if r["calls"] is not None:
        q = f"calls {r['calls']}"
    ver = version_of(r, versions) if r["target"] else "-"
    body = tilde(r["body"]["path"]) if r["body"] else "-"
    deny = sum(r["denials"].values())
    return (
        f"{r['id']}  {fmt_ts(r['ts'])}  {r['source']:<11} {clip(tilde(r['cwd']), 38):<38}  {r['via'] or '-':<5} "
        f"turns {r['turns']:<3} {q:<13} intr {r['interrupts']} err {r['errors']} deny {deny}  "
        f"{r['ended']}  ver {ver}  body {body}"
    )


def condense(events, only=None):
    """Numbered typed turns, answers and interrupts; per turn, the last assistant text and a tool summary."""
    out, tools, last_say, turn = [], [], None, 0

    def flush():
        nonlocal tools, last_say
        if tools:
            counts = {}
            for n in tools:
                counts[n] = counts.get(n, 0) + 1
            out.append("[tools] " + ", ".join(f"{k}×{v}" if v > 1 else k for k, v in counts.items()))
        if last_say:
            out.append("[agent] " + clip(last_say, WIDTH["say"]))
        tools, last_say = [], None

    names = {}
    for e in events:
        k = e["kind"]
        if k == "call":
            names.setdefault(e["call_id"], e)
            hit = only is not None and any(e is h for h in only)
            if only is None or hit:
                tools.append(e["name"])
            if hit:
                flush()
                out.append(f"[call] {e['name']}: {clip(json.dumps(e['input']), WIDTH['result'])}")
        elif k == "say":
            last_say = e["text"]
        elif k == "result" and (e["error"] or e["denial"]):
            call = names.get(e["call_id"]) or {}
            tag = f"denied {e['denial']}" if e["denial"] else "error"
            out.append(f"[{tag}] {call.get('name', '?')}: {clip(e['text'], WIDTH['result'])}")
        elif k == "result" and only is not None and any(names.get(e["call_id"]) is h for h in only):
            out.append(f"[result] {clip(e['text'], WIDTH['result'])}")
        elif k == "prompt":
            flush()
            turn += 1
            out.append(f"[you #{turn}] " + clip(e["text"], WIDTH["prompt"]))
        elif k == "answer":
            flush()
            for a in e["answers"]:
                note = f" — note: {clip(a['note'], 300)}" if a["note"] else ""
                out.append(f"[answer] {a['header'] or clip(a['question'] or '', 80)}: {clip(a['answer'], 300)} ({a['class']}){note}")
        elif k == "interrupt":
            flush()
            out.append("[interrupted]")
        elif k == "body":
            out.append(f"[skill body] {tilde(e['path'])}")
    flush()
    return out


def show(r, versions, max_lines):
    ver = version_of(r, versions) if r["target"] else "-"
    print(f"\n## run {r['id']} · {r['source']} · {fmt_ts(r['ts'])} · {tilde(r['cwd'])} · session {r['session']} · version {ver}")
    if r["source"] == "claude-work":
        print("(work profile: paraphrase, never quote)")
    if r["target"]:
        print(f"invoked {r['via']}: /{r['target']} {clip(r['args'] or '', 400)}")
    lines = condense(r["window"], only=r["hits"])
    if max_lines and len(lines) > max_lines:
        lines = lines[:max_lines] + [f"[… {len(lines) - max_lines} more lines; raise --max-lines to see them]"]
    print("\n".join(lines))
    print(f"[ended] {r['ended']}" + (f"; the prompt that ended it: {clip(r['after'], 600)}" if r["after"] else ""))


# ---------------------------------------------------------------------------
# Commands.


def git_root(path):
    out = subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else None


def cmd_runs(args):
    matcher = Matcher(args)
    if not (matcher.skills or matcher.tools or matcher.cmds or matcher.texts):
        sys.exit("runs: give at least one of --skill, --tool, --cmd, --text")
    sessions = all_sessions(matcher.prefilter(), args.subagents)
    runs = find_runs(sessions, matcher, args.since)
    versions = repo_versions(args.repo or git_root(os.getcwd()), matcher.skills)
    if args.show:
        wanted = None if args.show == "all" else set(args.show.split(","))
        for r in runs:
            if wanted is None or r["id"] in wanted:
                show(r, versions, args.max_lines)
        return
    if args.json:
        skip = ("window", "hits", "session_obj", "body")
        for r in runs:
            print(json.dumps({k: v for k, v in r.items() if k not in skip} | {"version": version_of(r, versions) if r["target"] else None}, default=str))
        return
    header(runs, matcher, sessions, args.since)
    print()
    for r in runs:
        print(run_line(r, versions))


def cmd_work(args):
    mention = re.compile(args.mention, re.I) if args.mention else None
    found = []
    for s in all_sessions(re.compile("|".join([re.escape(p) for p in args.path] + ([args.mention] if args.mention else [])), re.I)):
        if any(e["kind"] == "skill" and bare(e["name"]) == "mine" for e in s.events):
            continue
        edited = any(
            e["kind"] == "call" and e["name"] in EDIT_TOOLS and any(p in str(e["input"].get("file_path") or e["input"].get("path") or "") for p in args.path)
            for e in s.events
        )
        prompts = [e for e in s.events if e["kind"] == "prompt"]
        if edited or (mention and any(mention.search(e["text"]) for e in prompts)):
            found.append((s, prompts))
    for s, prompts in sorted(found, key=lambda x: x[0].started or "", reverse=True)[: args.limit]:
        print(f"\n## {s.source} · {fmt_ts(s.started)} · {tilde(s.cwd)} · session {s.id}")
        if s.source == "claude-work":
            print("(work profile: paraphrase, never quote)")
        for e in prompts:
            print("[you] " + clip(e["text"], 1000))
    print(f"\n{len(found)} sessions matched, newest {min(len(found), args.limit)} shown", file=sys.stderr)


def cmd_session(args):
    sessions = all_sessions()
    if args.id == "latest":
        cwd = os.path.realpath(args.cwd or os.getcwd())
        mine = [s for s in sessions if any(c and os.path.realpath(c) == cwd for c in s.cwds)]
        if not mine:
            sys.exit(f"session: no session ran in {cwd}")
        s = max(mine, key=lambda s: os.path.getmtime(s.path))
    else:
        s = next((s for s in sessions if args.id in s.id), None) or sys.exit(f"session: no session {args.id}")
    print(f"## {s.source} · {fmt_ts(s.started)} · {tilde(s.cwd)} · session {s.id}")
    print("\n".join(condense(s.events)))


def cmd_prompts(args):
    rows = []
    for s in all_sessions():
        first = next((e for e in s.events if e["kind"] == "prompt"), None)
        if not first or (args.since and (first["ts"] or "") < args.since):
            continue
        if args.source and s.source not in args.source:
            continue
        if args.cwd and args.cwd not in (s.cwd or ""):
            continue
        if args.grep and not re.search(args.grep, first["text"], re.I):
            continue
        rows.append({"source": s.source, "timestamp": first["ts"], "cwd": s.cwd, "session": s.id, "prompt": first["text"]})
    rows.sort(key=lambda r: r["timestamp"] or "")
    for r in rows:
        if args.json:
            print(json.dumps(r, ensure_ascii=False))
        else:
            print(f"{fmt_ts(r['timestamp'])}  {r['source']:<11} {clip(tilde(r['cwd']), 40):<40}  {clip(r['prompt'], args.width)}")
    print(f"{len(rows)} sessions", file=sys.stderr)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)
    r = sub.add_parser("runs")
    for flag in ("--skill", "--tool", "--cmd", "--text"):
        r.add_argument(flag, action="append")
    r.add_argument("--since", help="ISO date; runs that started before it are skipped")
    r.add_argument("--repo", help="repo whose skills/<name>/SKILL.md history names versions (default: cwd's)")
    r.add_argument("--subagents", action="store_true", help="also read Claude subagent transcripts")
    r.add_argument("--show", help="comma-separated run ids, or all")
    r.add_argument("--max-lines", type=int, default=150, help="per run in --show; 0 for no limit")
    r.add_argument("--json", action="store_true")
    w = sub.add_parser("work")
    w.add_argument("--path", action="append", required=True, help="substring of an edited file's path")
    w.add_argument("--mention", help="regex a typed turn must match")
    w.add_argument("--limit", type=int, default=10)
    s = sub.add_parser("session")
    s.add_argument("id", help="part of a session id, or latest")
    s.add_argument("--cwd")
    q = sub.add_parser("prompts")
    q.add_argument("--since")
    q.add_argument("--source", action="append", choices=["claude", "claude-work", "pi"], help="repeatable; default all")
    q.add_argument("--cwd")
    q.add_argument("--grep")
    q.add_argument("--json", action="store_true")
    q.add_argument("--width", type=int, default=160)
    args = p.parse_args()
    {"runs": cmd_runs, "work": cmd_work, "session": cmd_session, "prompts": cmd_prompts}[args.command](args)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        pass
