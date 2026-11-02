#!/usr/bin/env python3
"""Ledger of one Claude Code or pi session: where its money and time went, and which moments to examine.

  report [SESSION] [--top N]
      The ledger, then the moments its numbers select. Without SESSION: the current one.
  window SESSION FROM TO [--agent ID] [--grep REGEX] [--max-lines N]
      The condensed transcript of requests rFROM..rTO, to stdout. Nothing is written to disk.
      --grep lists the matching events' requests instead, to locate a moment you were told about.

SESSION is part of a session id. Sources: ~/.claude/projects, ~/.claude-work/projects,
~/.pi/agent/sessions. Everything from a session's last /retro onward is left out of the
analysis, and so are subagents started after it, so a retro never reviews itself.

Dollars are list price, never an invoice. Class totals are computed from recorded usage. Item
costs are estimates: each arrival is sized by how much the context grew, and each request's read,
write and input bands are laid over the prefix. A cache-miss premium is charged to its event, not
to the items that had to be rewritten. "Share while present" is not what removing an item saves.

Transcript fields are undocumented and can change in any release; what a session doesn't record
prints as "not available". Compare `unattributed` between runs to notice the parser drifting.
"""

import argparse
import bisect
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime

HOME = os.path.expanduser("~")
CLAUDE_ROOTS = [("claude", f"{HOME}/.claude/projects"), ("claude-work", f"{HOME}/.claude-work/projects")]
PI_ROOT = f"{HOME}/.pi/agent/sessions"

PRICES_READ = "2026-11-02"
# Per MTok: base input, cache read, output. Writes are 1.25x (5m) and 2x (1h) of base everywhere.
# Most specific prefix first, since "claude-opus-5" also matches "claude-opus-5-5".
PRICES = [
    ("claude-fable-5-1", 10, 0.25, 50),
    ("claude-mythos-5-1", 10, 0.25, 50),
    ("claude-fable-5", 10, 1, 50),
    ("claude-mythos-5", 10, 1, 50),
    ("claude-opus-5-5", 4, 0.20, 20),
    ("claude-opus-5", 5, 0.50, 25),
    ("claude-opus-4-8", 5, 0.50, 25),
    ("claude-opus-4-7", 5, 0.50, 25),
    ("claude-opus-4-6", 5, 0.50, 25),
    ("claude-opus-4-5", 5, 0.50, 25),
    ("claude-sonnet-5-5", 2, 0.10, 10),
    ("claude-sonnet-5", 2, 0.20, 10),
    ("claude-sonnet-4-6", 3, 0.30, 15),
    ("claude-sonnet-4-5", 3, 0.30, 15),
    ("claude-haiku-5-5", 0.10, 0.01, 0.50),  # prompts up to 100k; see HAIKU_LONG
    ("claude-haiku-4-5", 1, 0.10, 5),
]
HAIKU_LONG = (0.50, 0.05, 2.50)
FAST_OPUS_5_5 = (8, 0.40, 40)
NO_US_PREMIUM = ("claude-opus-4-5", "claude-sonnet-4-5", "claude-haiku-4-5")

HUMAN_TOOLS = {"AskUserQuestion", "ExitPlanMode", "ask_user_question"}
READ_TOOLS = {"Read", "read"}
EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit", "edit", "write"}
BASH_TOOLS = {"Bash", "bash"}
# Destructive commands and guard bypasses. An rm counts only outside /tmp and past a bare relative name.
RISKY = re.compile(
    r"\brm\s+-[a-z]*(?:rf|fr)[a-z]*\s+(?:--\s+)?(?!/tmp\b)[/~$*.]|\bgit\s+reset\s+--hard|\bgit\s+clean\s+-[a-z]*f"
    r"|\bgit\s+push\b[^|;&\n]*(?:--force|\s-f\b)|--no-verify|\"dangerouslyDisableSandbox\": true"
)
# Attachments that reach the model; the rest are harness bookkeeping.
CONTEXT_ATTACHMENTS = {
    "file", "edited_text_file", "diagnostics", "instructions", "skill_listing", "mcp_instructions_delta",
    "deferred_tools_delta", "agent_listing_delta", "session_context", "environment", "queued_command", "skill_mention",
}  # fmt: skip
CLAUDE_NOISE = ("Another Claude", "This session is being continued", "The summarized", "Caveat:", "<local-command-", "<bash-stdout", "<bash-stderr", "<task-notification", "<artifact-")
CHARS_PER_TOKEN = 4
IMAGE_CHARS = 6000  # an image's base64 says nothing about its tokens; about 1.5k tokens each
CAP_MINUTES = 15  # WakaTime's default; a convention, which is why the report also shows CAPS
CAPS = (5, 15, 30)
BUST_MIN_LOST = 1024
BUST_MIN_SHARE = 0.2
SHRINK_SHARE = 0.5
LOOK_BACK = 10  # the signal of a decisive error tends to trail it, so windows start earlier
LOOK_AHEAD = 3
MOMENTS_MAX = 5
COST_FLOOR_USD = 0.25
COST_FLOOR_SHARE = 0.03
TIME_FLOOR_S = 120
TIME_FLOOR_SHARE = 0.02


_warned_zstd = False


def lines_of(path):
    global _warned_zstd
    if path.endswith(".zst"):
        if not shutil.which("zstd"):
            if not _warned_zstd:
                print("spend: zstd not on PATH, skipping compressed transcripts", file=sys.stderr)
                _warned_zstd = True
            return []
        return subprocess.run(["zstd", "-dcq", path], capture_output=True, text=True, errors="replace").stdout.splitlines()
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


def seconds(ts):
    if isinstance(ts, (int, float)):
        return ts / 1000
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def clip(text, width):
    text = " ".join(str(text).split())
    return text if len(text) <= width else text[: width - 1] + "…"


def tilde(path):
    return (path or "?").replace(HOME, "~", 1)


def text_of(content):
    """A message's text, and its size with images counted by their token cost rather than their base64."""
    if isinstance(content, str):
        return content, len(content)
    parts, size = [], 0
    for b in content or ():
        if not isinstance(b, dict):
            continue
        if b.get("type") == "text":
            parts.append(b.get("text", ""))
            size += len(b.get("text", ""))
        elif b.get("type") == "image":
            size += IMAGE_CHARS
    return "\n".join(parts), size


def price_of(model, speed=None, geo=None, prompt_tokens=0):
    """(input, read, 5m write, 1h write, output) per token at list price, or None for an unknown model."""
    name = (model or "").split("[")[0]
    row = next((p for p in PRICES if name.startswith(p[0])), None)
    if not row:
        return None
    base, read, out = row[1:]
    if row[0] == "claude-haiku-5-5" and prompt_tokens > 100_000:
        base, read, out = HAIKU_LONG
    if row[0] == "claude-opus-5-5" and speed == "fast":
        base, read, out = FAST_OPUS_5_5
    scale = 1.1 if geo == "us" and row[0] not in NO_US_PREMIUM else 1
    return tuple(x * scale / 1e6 for x in (base, read, base * 1.25, base * 2, out))


# ---------------------------------------------------------------------------
# Parsing: both harnesses become requests plus an ordered list of events.


class Request:
    def __init__(self, key, model, ts):
        self.key = key
        self.model = model
        self.first_ts = self.last_ts = ts
        self.n = 0  # rN on its chain, set once the chain is cut
        self.input = self.read = self.w5m = self.w1h = self.output = self.thinking = self.thinking_ms = 0
        self.speed = self.geo = None
        self.stored_cost = None  # pi records dollars per class itself
        self.skill = self.effort = None
        self.calls = []

    @property
    def write(self):
        return self.w5m + self.w1h

    @property
    def context(self):
        return self.input + self.read + self.write

    def costs(self):
        """Dollars per class, or None when neither a stored cost nor a price exists."""
        if self.stored_cost:
            c = self.stored_cost
            if c.get("total"):
                return {"input": c.get("input", 0), "read": c.get("cacheRead", 0), "write": c.get("cacheWrite", 0), "output": c.get("output", 0)}
        p = price_of(self.model, self.speed, self.geo, self.context)
        if not p:
            return None
        return {"input": self.input * p[0], "read": self.read * p[1], "write": self.w5m * p[2] + self.w1h * p[3], "output": self.output * p[4]}

    @property
    def cost(self):
        c = self.costs()
        return sum(c.values()) if c else 0


class Session:
    def __init__(self, source, path):
        self.source = source
        self.path = path
        self.id = os.path.basename(path).split(".")[0]
        self.cwd = None
        self.events = []
        self.requests = []
        self.records = 0
        self.cost_state = None
        self.excluded_cost = 0
        self.cut_ts = None
        self.children = []
        self.meta = {}

    def add(self, kind, ts, **fields):
        self.events.append({"kind": kind, "ts": seconds(ts), **fields})


def call_label(name, inp):
    inp = inp if isinstance(inp, dict) else {}
    target = inp.get("file_path") or inp.get("path") or inp.get("command") or inp.get("description") or inp.get("skill") or inp.get("query") or inp.get("pattern")
    if target is None:
        target = next((v for v in inp.values() if isinstance(v, str)), "")
    return f"{name}: {clip(tilde(str(target)), 70)}" if target else str(name)


def parse_claude(source, path, seen):
    """`seen` holds request keys across a session's files: a fork replays its parent's records."""
    s = Session(source, path)
    groups = {}
    for r in records(path):
        kind, ts = r.get("type"), r.get("timestamp")
        s.cwd = s.cwd or r.get("cwd")
        if kind == "cost-state":
            s.cost_state = r
            continue
        if kind == "system":
            sub = r.get("subtype")
            if sub == "compact_boundary":
                m = r.get("compactMetadata") or {}
                s.add("compact", ts, pre=m.get("preTokens"), post=m.get("postTokens"), duration=(m.get("durationMs") or 0) / 1000, trigger=m.get("trigger"))
            elif sub == "turn_duration":
                s.add("turn_end", ts, pending=r.get("pendingBackgroundAgentCount") or 0)
            elif sub == "stop_hook_summary" and (r.get("preventedContinuation") or r.get("hookErrors")):
                s.add("hook", ts, blocked=bool(r.get("preventedContinuation")), errors=len(r.get("hookErrors") or ()))
            elif sub in ("scheduled_task_fire", "away_summary"):
                s.add("idle_work", ts, what=sub)
            continue
        if kind == "attachment":
            a = r.get("attachment") or {}
            if a.get("type") == "queued_command" and (a.get("origin") or {}).get("kind") == "human":
                s.add("queued", ts)
            if a.get("type") in CONTEXT_ATTACHMENTS:
                s.add("arrival", ts, label=f"attachment: {a.get('type')}", chars=len(json.dumps(a)))
            continue
        msg = r.get("message") or {}
        content = msg.get("content")
        if kind == "assistant":
            if r.get("isApiErrorMessage"):
                s.add("api_error", ts)
            s.records += 1
            if msg.get("model") == "<synthetic>" or not msg.get("id"):
                continue
            key = (msg.get("id"), r.get("requestId"))
            if key in seen and key not in groups:
                continue
            seen.add(key)
            req = groups.get(key)
            if req is None:
                req = groups[key] = Request(key, msg.get("model"), ts)
                s.requests.append(req)
                s.add("request", ts, req=req)
            req.last_ts = ts
            req.skill = req.skill or r.get("attributionSkill")
            req.effort = req.effort or r.get("perTurnEffort")
            req.thinking_ms = max(req.thinking_ms, r.get("thinkingDurationMs") or 0)
            u = msg.get("usage") or {}
            cc = u.get("cache_creation") or {}
            # Older logs fill usage in as the stream goes, so the per-field max is right on old and new alike.
            req.input = max(req.input, u.get("input_tokens") or 0)
            req.read = max(req.read, u.get("cache_read_input_tokens") or 0)
            req.output = max(req.output, u.get("output_tokens") or 0)
            req.thinking = max(req.thinking, (u.get("output_tokens_details") or {}).get("thinking_tokens") or 0)
            w5m = cc.get("ephemeral_5m_input_tokens") or 0
            w1h = cc.get("ephemeral_1h_input_tokens") or 0
            total_write = u.get("cache_creation_input_tokens") or 0
            if not cc and total_write:
                w5m = total_write  # logs without the split: assume the cheaper TTL
            req.w5m = max(req.w5m, w5m)
            req.w1h = max(req.w1h, w1h)
            req.speed = req.speed or u.get("speed")
            req.geo = req.geo or u.get("inference_geo")
            s.add("tick", ts, what="model")
            for b in content or ():
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "text" and b.get("text", "").strip():
                    s.add("say", ts, text=b["text"])
                elif b.get("type") == "thinking" and (b.get("thinking") or "").strip():
                    s.add("think", ts, text=b["thinking"])
                elif b.get("type") == "tool_use":
                    req.calls.append(b.get("name"))
                    s.add("call", ts, req=req, call_id=b.get("id"), name=b.get("name"), input=b.get("input") or {})
            continue
        if kind != "user":
            continue
        text, size = text_of(content)
        if r.get("isCompactSummary"):
            s.add("arrival", ts, label="compaction summary", chars=size)
            continue
        if r.get("isMeta"):
            m = re.match(r"Base directory for this skill: (\S+)", text)
            label = f"skill body: {os.path.basename(m.group(1).rstrip('/'))}" if m else "harness text"
            s.add("arrival", ts, label=label, chars=size)
            continue
        results = [b for b in content if isinstance(b, dict) and b.get("type") == "tool_result"] if isinstance(content, list) else []
        if results:
            tur = r.get("toolUseResult") if isinstance(r.get("toolUseResult"), dict) else {}
            decision = r.get("permissionDecision") if isinstance(r.get("permissionDecision"), dict) else {}
            prompted = str(decision.get("source") or "").startswith("user")
            s.add("tick", ts, what="permission" if prompted else "tool")
            for b in results:
                out, n = text_of(b.get("content"))
                s.add(
                    "result",
                    ts,
                    call_id=b.get("tool_use_id"),
                    error=bool(b.get("is_error")),
                    denial=r.get("toolDenialKind"),
                    source=decision.get("source"),
                    prompted=prompted,
                    text=out,
                    chars=n,
                    truncated=bool(tur.get("persistedOutputPath")),
                    agent_id=tur.get("agentId"),
                )
            continue
        text = re.sub(r"^(\s*<system-reminder>.*?</system-reminder>)+", "", text, flags=re.S).strip()
        if not text:
            continue
        if text.startswith("[Request interrupted"):
            s.add("interrupt", ts)
            continue
        origin = r.get("origin")
        human = (origin or {}).get("kind") == "human" if origin is not None else not text.startswith(CLAUDE_NOISE)
        if not human:
            s.add("tick", ts, what="background")
            s.add("arrival", ts, label=f"notice: {(origin or {}).get('kind') or 'harness'}", chars=size)
            continue
        name = re.search(r"<command-name>/?(?:[\w-]+:)?([\w-]+)</command-name>", text[:300])
        if name and name.group(1) == "retro":
            s.add("retro", ts)
        s.add("tick", ts, what="user")
        s.add("prompt", ts, text=re.sub(r"</?(command-[a-z]+)>", " ", text).strip(), chars=size)
    return s


def parse_pi(path):
    s = Session("pi", path)
    for r in records(path):
        ts, kind = r.get("timestamp"), r.get("type")
        if kind == "session":
            s.cwd, s.id = r.get("cwd"), r.get("id") or s.id
            continue
        if kind == "compaction":
            s.add("compact", ts, pre=r.get("tokensBefore"), post=None, duration=0, trigger=None)
            s.add("arrival", ts, label="compaction summary", chars=len(r.get("summary") or ""))
            continue
        if kind != "message":
            continue
        m = r.get("message") or {}
        role = m.get("role")
        if role == "assistant":
            u = m.get("usage") or {}
            s.records += 1
            req = Request(r.get("id"), m.get("model"), ts)
            req.input, req.read, req.w5m, req.output = (u.get(k) or 0 for k in ("input", "cacheRead", "cacheWrite", "output"))
            req.thinking = u.get("reasoning") or 0
            req.stored_cost = u.get("cost") if isinstance(u.get("cost"), dict) else None
            req.effort = m.get("thinkingLevel")
            s.requests.append(req)
            s.add("request", ts, req=req)
            s.add("tick", ts, what="model")
            for b in m.get("content") or ():
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "text" and b.get("text", "").strip():
                    s.add("say", ts, text=b["text"])
                elif b.get("type") == "thinking" and (b.get("thinking") or "").strip():
                    s.add("think", ts, text=b["thinking"])
                elif b.get("type") == "toolCall":
                    req.calls.append(b.get("name"))
                    s.add("call", ts, req=req, call_id=b.get("id"), name=b.get("name"), input=b.get("arguments") or {})
            if m.get("stopReason") == "aborted":
                s.add("interrupt", ts)
            elif m.get("stopReason") == "error":
                s.add("api_error", ts)
        elif role == "toolResult":
            out, n = text_of(m.get("content"))
            details = m.get("details") if isinstance(m.get("details"), dict) else {}
            prompted = m.get("toolName") in HUMAN_TOOLS
            s.add("tick", ts, what="permission" if prompted else "tool")
            s.add("result", ts, call_id=m.get("toolCallId"), error=bool(m.get("isError")), denial=None, source=None, prompted=prompted, text=out, chars=n, truncated=bool(details.get("truncated")), agent_id=None)
        elif role == "user":
            text, n = text_of(m.get("content"))
            if not text.strip():
                continue
            sk = re.match(r'<skill name="([^"]+)" location="[^"]+">\n?(.*?)</skill>\s*(.*)', text, re.S)
            if sk and sk.group(1) == "retro":
                s.add("retro", ts)
            s.add("tick", ts, what="user")
            if sk:
                s.add("arrival", ts, label=f"skill body: {sk.group(1)}", chars=len(sk.group(2)))
                s.add("skill_start", ts, name=sk.group(1))
                s.add("prompt", ts, text=f"/skill:{sk.group(1)} {sk.group(3)}".strip(), chars=len(sk.group(3)))
            else:
                s.add("prompt", ts, text=text, chars=n)
    return s


def cut_at_retro(s):
    """Drop everything from the session's last /retro on, but keep its dollars for the reconciliation."""
    last = max((i for i, e in enumerate(s.events) if e["kind"] == "retro"), default=None)
    if last is not None:
        s.cut_ts = s.events[last]["ts"]
        kept = {id(e["req"]) for e in s.events[:last] if e["kind"] == "request"}
        s.excluded_cost = sum(r.cost for r in s.requests if id(r) not in kept)
        s.requests = [r for r in s.requests if id(r) in kept]
        s.events = s.events[:last]
    for n, r in enumerate(s.requests, 1):
        r.n = n


def load_children(s):
    """Subagent sessions, deepest included; a fork's replayed parent records count once."""
    seen = {r.key for r in s.requests}
    if s.source == "pi":
        children = pi_children(s)
    else:
        base = re.sub(r"\.jsonl(\.zst)?$", "", s.path)
        paths = sorted(glob.glob(f"{base}/subagents/**/*.jsonl*", recursive=True))
        children = []
        for p in paths:
            c = parse_claude(s.source, p, seen)
            meta_path = re.sub(r"\.jsonl(\.zst)?$", ".meta.json", p)
            if os.path.exists(meta_path):
                try:
                    with open(meta_path) as f:
                        c.meta.update(json.load(f))
                except (OSError, ValueError):
                    pass
            c.id = re.sub(r"^agent-", "", c.id)
            children.append(c)
    kept = []
    for c in children:
        first = next((e["ts"] for e in c.events if e["ts"]), None)
        if s.cut_ts and first and first >= s.cut_ts:
            s.excluded_cost += sum(r.cost for r in c.requests)
            continue
        for n, r in enumerate(c.requests, 1):
            r.n = n
        if c.requests:
            kept.append(c)
    s.children = kept


def pi_children(s):
    out = []
    own_ids = None
    for p in glob.glob(f"{PI_ROOT}/*/*.jsonl"):
        if p == s.path:
            continue
        try:
            with open(p, errors="replace") as f:
                head = json.loads(f.readline() or "{}")
        except (OSError, ValueError):
            continue
        if head.get("parentSession") not in (s.path, s.id):
            continue
        if own_ids is None:
            own_ids = {r.get("id") for r in records(s.path) if r.get("type") != "session"}
        # A fork copies its parent's entries; a subagent shares none.
        if own_ids & {r.get("id") for r in records(p) if r.get("type") != "session"}:
            continue
        out.append(parse_pi(p))
    return out


# ---------------------------------------------------------------------------
# Locating the session.


def pi_files_by_cwd(cwd):
    found = []
    for p in glob.glob(f"{PI_ROOT}/*/*.jsonl"):
        try:
            with open(p, errors="replace") as f:
                head = json.loads(f.readline() or "{}")
        except (OSError, ValueError):
            continue
        if head.get("cwd") and os.path.realpath(head["cwd"]) == cwd and not head.get("parentSession"):
            found.append(p)
    return sorted(found, key=os.path.getmtime, reverse=True)


def resolve(session):
    """(source, path) of a named session, or of the current one; says so on stderr when it had to guess."""
    if not session:
        sid = os.environ.get("CLAUDE_CODE_SESSION_ID")
        if sid:
            session = sid
        else:
            found = pi_files_by_cwd(os.path.realpath(os.getcwd()))
            if not found:
                sys.exit(f"spend: no session ran in {os.getcwd()}; name one")
            print(f"spend: picked the newest pi session here: {found[0]}", file=sys.stderr)
            others = [p for p in found[1:] if time.time() - os.path.getmtime(p) < 600]
            for p in others:
                print(f"spend: also active in the last 10 minutes: {p}", file=sys.stderr)
            return "pi", found[0]
    hits = []
    for source, root in CLAUDE_ROOTS:
        hits += [(source, p) for p in glob.glob(f"{root}/*/*{session}*.jsonl*")]
    hits += [("pi", p) for p in glob.glob(f"{PI_ROOT}/*/*{session}*.jsonl")]
    if not hits:
        sys.exit(f"spend: no session matches {session}")
    if len({os.path.basename(p).split(".")[0] for _, p in hits}) > 1:
        sys.exit("spend: more than one session matches:\n" + "\n".join(p for _, p in hits))
    # A worktree or resume can store the same id twice: the largest copy holds the most.
    return max(hits, key=lambda h: os.path.getsize(h[1]))


def load(session):
    source, path = resolve(session)
    s = parse_pi(path) if source == "pi" else parse_claude(source, path, set())
    cut_at_retro(s)
    load_children(s)
    return s


# ---------------------------------------------------------------------------
# Time: one exclusive sweep of the main chain, each gap classed by the event that ended it.


def sweep(s, cap_s):
    b = dict.fromkeys(("model", "compaction", "tool", "permission", "background", "engaged", "away"), 0.0)
    raw_human = 0.0
    gaps = []
    human_gaps = []
    prev, pending, req = None, 0, None
    for e in s.events:
        k = e["kind"]
        if k == "request":
            req = e["req"]
        if k == "turn_end":
            pending = e["pending"]
        if k not in ("tick", "compact") or e["ts"] is None:
            continue
        if prev is None:
            prev = e["ts"]
            continue
        gap = max(0.0, e["ts"] - prev)
        prev = e["ts"]
        what = "compaction" if k == "compact" else e["what"]
        if what == "user" and pending:
            what = "background"
        if what in ("user", "permission"):
            human_gaps.append(gap)
            raw_human += gap
            kept = min(gap, cap_s)
            b["away"] += gap - kept
            b["permission" if what == "permission" else "engaged"] += kept
        else:
            b[what] += gap
            gaps.append({"what": what, "seconds": gap, "req": req.n if req else 1})
    return {"buckets": b, "raw_human": raw_human, "human_gaps": human_gaps, "gaps": gaps}


def duration(s):
    ts = [e["ts"] for e in s.events if e["ts"]]
    return (max(ts) - min(ts)) if ts else 0


# ---------------------------------------------------------------------------
# Item ledger: walk each request's prefix against its read, write and input bands.


class Item:
    def __init__(self, label, kind, born, size=0):
        self.label, self.kind, self.born, self.size = label, kind, born, size
        self.cost = 0.0
        self.requests = 0
        self.call_id = None


def allocate(s):
    """Items and cache-miss events of the main chain, conserving each request's input-side dollars."""
    done, events, compactions = [], [], []
    items, ends, full_rate = [], [], [0.0]  # full_rate[k]: read rate owed by every item below index k
    arrivals, prev, prev_ts, boundary = [], None, None, None
    negative = 0

    def close(last_n):
        rate = 0.0
        for i in range(len(items) - 1, -1, -1):
            rate += full_rate[i + 1]
            items[i].cost += items[i].size * rate
            items[i].requests = last_n - items[i].born + 1
        done.extend(items)

    def grow(item):
        items.append(item)
        ends.append((ends[-1] if ends else 0) + item.size)
        full_rate.append(0.0)

    for e in s.events:
        k = e["kind"]
        if k == "arrival":
            arrivals.append((e["label"], "context", e["chars"], None))
        elif k == "prompt":
            arrivals.append(("prompt", "prompt", e["chars"], None))
        elif k == "result":
            arrivals.append((None, "tool", e["chars"], e["call_id"]))
        elif k == "compact":
            boundary = e
        elif k == "request":
            req = e["req"]
            T = req.context
            costs = req.costs()
            shrink = prev is not None and prev.context > 5000 and T < prev.context * SHRINK_SHARE
            if prev is None or boundary or shrink:
                if prev is not None:
                    close(prev.n)
                    items, ends, full_rate = [], [], [0.0]
                sized = [(lab, kind, ch // CHARS_PER_TOKEN, cid) for lab, kind, ch, cid in arrivals]
                rest = max(0, T - sum(x[2] for x in sized))
                base = "startup context" if prev is None else ("context after compaction" if boundary else "context after shrink")
                grow(Item(base, "base", req.n, rest))
            else:
                new = T - prev.context - prev.output
                if new < 0:
                    negative += 1
                    new = 0
                grow(Item(output_label(prev), "output", prev.n + 1, prev.output))
                chars = sum(x[2] for x in arrivals)
                sized = [(lab, kind, round(new * ch / chars) if chars else 0, cid) for lab, kind, ch, cid in arrivals]
                if not arrivals and new:
                    sized = [("unlabelled growth", "context", new, None)]
            for lab, kind, size, cid in sized:
                item = Item(lab, kind, req.n, size)
                item.call_id = cid
                grow(item)
            arrivals = []
            if ends[-1] < T:
                grow(Item("unsized context", "context", req.n, T - ends[-1]))

            # Band rates, per token. A miss's rewrite is priced as a read here; the difference is the event's.
            r_read = (costs["read"] / req.read) if costs and req.read else 0
            r_in = (costs["input"] / req.input) if costs and req.input else 0
            r_write = (costs["write"] / req.write) if costs and req.write else 0
            lost = 0
            if prev is not None:
                missing = prev.context - req.read
                if missing > max(BUST_MIN_LOST, BUST_MIN_SHARE * prev.context) and req.write:
                    lost = min(missing, req.write)
            if lost:
                gap = (seconds(req.first_ts) or 0) - (seconds(prev_ts) or 0)
                ttl = 3600 if prev.w1h or req.w1h else 300
                if boundary:
                    cause = "compaction"
                elif req.model != prev.model:
                    cause = "model change"
                elif gap > ttl:
                    cause = f"gap over {'1h' if ttl == 3600 else '5m'} TTL"
                elif shrink:
                    cause = "context shrank"
                else:
                    cause = "warm bust"
                events.append({"req": req.n, "lost": lost, "premium": lost * max(0.0, r_write - r_read), "cause": cause, "gap": gap})
            k_full = bisect.bisect_right(ends, req.read)
            if k_full:
                full_rate[k_full] += r_read  # applied to items below k_full when the segment closes
            bands = ((req.read, r_read), (req.read + lost, r_read), (req.read + req.write, r_write), (T, r_in))
            start = ends[k_full - 1] if k_full else 0
            for i in range(k_full, len(items)):
                a, b = start, ends[i]
                start = b
                lo = 0
                for hi, rate in bands:
                    overlap = min(b, hi) - max(a, lo)
                    if overlap > 0:
                        items[i].cost += overlap * rate
                    lo = max(lo, hi)
                if a >= T:
                    break
            if boundary:
                compactions.append({"req": req.n, "pre": boundary.get("pre") or (prev.context if prev else 0), "post": boundary.get("post") or T, "duration": boundary.get("duration") or 0, "trigger": boundary.get("trigger"), "rebuild": costs["write"] if costs else 0, "r_read": r_read})
            boundary = None
            prev, prev_ts = req, req.last_ts
    if prev is not None:
        close(prev.n)
    return done, events, compactions, negative


def output_label(req):
    heavy = [c for c in req.calls if c in EDIT_TOOLS or c in BASH_TOOLS]
    return f"output of r{req.n}" + (f" ({', '.join(sorted(set(heavy)))})" if heavy else "")


# ---------------------------------------------------------------------------
# Tools, subagents, skills, turns and friction.


def call_table(s):
    calls = {}
    for e in s.events:
        if e["kind"] == "call":
            calls[e["call_id"]] = {"name": e["name"], "input": e["input"], "req": e["req"].n, "ts": e["ts"], "result": None}
        elif e["kind"] == "result" and e["call_id"] in calls:
            calls[e["call_id"]]["result"] = e
    return calls


def tool_rows(calls, items_by_call):
    rows = {}
    for cid, c in calls.items():
        row = rows.setdefault(c["name"], {"calls": 0, "errors": 0, "seconds": 0.0, "prompted": 0.0, "tokens": 0, "cost": 0.0})
        row["calls"] += 1
        r = c["result"]
        if r:
            row["errors"] += r["error"] or bool(r["denial"])
            if r["ts"] and c["ts"]:
                row["prompted" if r["prompted"] else "seconds"] += max(0.0, r["ts"] - c["ts"])
        item = items_by_call.get(cid)
        if item:
            row["tokens"] += item.size
            row["cost"] += item.cost
    return rows


def subagent_rows(s, calls):
    by_agent = {}
    by_tool_use = {}
    for cid, c in calls.items():
        by_tool_use[cid] = c
        if c["result"] and c["result"].get("agent_id"):
            by_agent[c["result"]["agent_id"]] = c
    rows = []
    for child in s.children:
        c = by_agent.get(child.id) or by_tool_use.get(child.meta.get("toolUseId"))
        ts = [e["ts"] for e in child.events if e["ts"]]
        rows.append(
            {
                "id": child.id,
                "type": child.meta.get("agentType") or (c or {}).get("input", {}).get("subagent_type") or "?",
                "description": child.meta.get("description") or (c or {}).get("input", {}).get("description") or "",
                "model": ",".join(sorted({r.model or "?" for r in child.requests})),
                "requests": len(child.requests),
                "cost": sum(r.cost for r in child.requests),
                "first_write": sum((r.costs() or {}).get("write", 0) for r in child.requests[:1]),
                "tokens": sum(r.context + r.output for r in child.requests),
                "seconds": (max(ts) - min(ts)) if ts else 0,
                "returned": (c["result"] or {}).get("chars") if c and c["result"] else None,
                "req": c["req"] if c else None,
            }
        )
    return sorted(rows, key=lambda r: -r["cost"])


def skill_rows(s):
    """Dollars and requests per skill: Claude tags requests itself, pi's are the span up to the next prompt."""
    rows = {}
    if s.source == "pi":
        active = None
        for e in s.events:
            if e["kind"] == "skill_start":
                active = e["name"]
            elif e["kind"] == "prompt" and not e["text"].startswith("/skill:"):
                active = None
            elif e["kind"] == "request" and active:
                e["req"].skill = active
    for r in s.requests:
        if r.skill:
            row = rows.setdefault(r.skill, {"requests": 0, "cost": 0.0})
            row["requests"] += 1
            row["cost"] += r.cost
    return dict(sorted(rows.items(), key=lambda kv: -kv[1]["cost"]))


def turn_rows(s, subagents):
    turns, cur, prompts = [], None, 0
    for e in s.events:
        if e["kind"] == "prompt":
            prompts += 1
            cur = {"n": prompts, "text": e["text"], "requests": [], "ts": e["ts"], "end": e["ts"]}
            turns.append(cur)
        elif e["kind"] == "request":
            if cur is None:
                cur = {"n": 0, "text": "", "requests": [], "ts": e["ts"], "end": e["ts"]}
                turns.append(cur)
            cur["requests"].append(e["req"])
        if cur is not None and e["ts"] and e["kind"] != "prompt":
            cur["end"] = e["ts"]
    for t in turns:
        ns = {r.n for r in t["requests"]}
        t["cost"] = sum(r.cost for r in t["requests"]) + sum(a["cost"] for a in subagents if a["req"] in ns)
        t["from"] = min(ns) if ns else None
        t["to"] = max(ns) if ns else None
    return turns


def friction(s, calls):
    """Each event: where it happened, what it was, how bad its kind is (3 = you stepped in)."""
    out = []
    req = 0
    streak = 0
    reads = {}  # path → read count since it last changed
    failed = set()  # calls that failed with nothing changed since: re-running after a fix is no friction
    for e in s.events:
        k = e["kind"]
        if k == "request":
            req = e["req"].n
        elif k == "interrupt":
            out.append({"req": req, "what": "interrupted", "weight": 3})
        elif k == "queued":
            out.append({"req": req, "what": "you queued a message mid-turn", "weight": 2})
        elif k == "api_error":
            out.append({"req": req, "what": "API error", "weight": 1})
        elif k == "hook":
            if e["blocked"]:
                out.append({"req": req, "what": "a hook prevented continuing", "weight": 2})
            elif e["errors"]:
                out.append({"req": req, "what": f"hook errors: {e['errors']}", "weight": 1})
        elif k == "call":
            sig = json.dumps([e["name"], e["input"]], sort_keys=True, default=str)
            if sig in failed:
                out.append({"req": req, "what": f"same call repeated after an error: {call_label(e['name'], e['input'])}", "weight": 2})
            path = str(e["input"].get("file_path") or e["input"].get("path") or "")
            if e["name"] in EDIT_TOOLS:
                failed.clear()
                reads.pop(path, None)
            elif path and e["name"] in READ_TOOLS:
                reads[path] = reads.get(path, 0) + 1
                if reads[path] == 3:
                    out.append({"req": req, "what": f"re-read 3+ times with no edit between: {clip(tilde(path), 70)}", "weight": 1})
        elif k == "compact":
            reads.clear()  # re-reading after a compaction is expected, and the compaction is its own line
        elif k == "result":
            c = calls.get(e["call_id"]) or {}
            if e["denial"]:
                weight = 3 if e["denial"] in ("user-rejected", "interrupted") else 2
                out.append({"req": req, "what": f"denied ({e['denial']}): {call_label(c.get('name'), c.get('input'))}", "weight": weight})
            if e["truncated"]:
                out.append({"req": req, "what": f"output truncated: {call_label(c.get('name'), c.get('input'))}", "weight": 1})
            if e["error"]:
                streak += 1
                sig = json.dumps([c.get("name"), c.get("input")], sort_keys=True, default=str)
                failed.add(sig)
                if streak == 3:
                    out.append({"req": req, "what": f"3+ errors in a row, starting near {call_label(c.get('name'), c.get('input'))}", "weight": 2})
            else:
                streak = 0
                failed.clear()
    return out


def risky_calls(s):
    out = []
    for e in s.events:
        if e["kind"] == "call" and e["name"] in BASH_TOOLS:
            blob = json.dumps(e["input"])
            m = RISKY.search(blob)
            if m:
                out.append({"req": e["req"].n, "what": m.group(0), "label": call_label(e["name"], e["input"])})
    return out


# ---------------------------------------------------------------------------
# Moments: rules fixed before anyone reads the session.


def select_moments(total, active, items, turns, subagents, sweep_result, frictions, risks, busts, last_req):
    cost_floor = max(COST_FLOOR_USD, COST_FLOOR_SHARE * total)
    time_floor = max(TIME_FLOOR_S, TIME_FLOOR_SHARE * active)

    def window(at, start=None):
        lo = at - LOOK_BACK if start is None else min(start, at - LOOK_BACK)
        return max(1, lo), min(last_req, at + LOOK_AHEAD)

    def share_of_cost(d):
        return d / total if total else 0

    pools = {"cost": [], "time": [], "friction": []}
    for it in items:
        if it.kind == "base" or it.cost < cost_floor:
            continue
        pools["cost"].append({"kind": "cost", "at": it.born, "why": f"{it.label or 'tool result'}: ~{it.size:,} tok for {it.requests} requests, ${it.cost:.2f} while present", "share": share_of_cost(it.cost), "shape": "result-dominated"})
    for t in turns:
        if t["from"] is None or t["cost"] < cost_floor:
            continue
        top = max((i for i in items if t["from"] <= i.born <= t["to"] and i.kind != "base"), key=lambda i: i.cost, default=None)
        dominated = top is not None and top.cost >= 0.3 * t["cost"]
        delegated = sum(a["cost"] for a in subagents if a["req"] is not None and t["from"] <= a["req"] <= t["to"])
        shape = "subagent-dominated" if delegated >= 0.5 * t["cost"] else "result-dominated" if dominated else "turn-dominated" if len(t["requests"]) >= 20 else "short turn"
        why = f"prompt #{t['n']}: {len(t['requests'])} requests, ${t['cost']:.2f} with its subagents"
        moment = {"kind": "cost", "why": why, "share": share_of_cost(t["cost"]), "shape": shape}
        # A turn with one heavy item is about that item; otherwise it is about the turn, so start at its prompt.
        moment |= {"at": top.born} if dominated else {"at": t["from"], "start": t["from"], "cap": t["to"]}
        pools["cost"].append(moment)
    for a in subagents:
        if a["req"] and a["cost"] >= cost_floor:
            ret = f", returned {a['returned']:,} chars" if a["returned"] is not None else ""
            pools["cost"].append({"kind": "cost", "at": a["req"], "why": f"subagent {a['type']} ({clip(a['description'], 40)}): ${a['cost']:.2f}, {fmt_s(a['seconds'])}{ret}", "share": share_of_cost(a["cost"]), "shape": "subagent", "agent": a["id"]})
    for b in busts:
        if b["premium"] >= cost_floor and b["cause"] != "compaction":
            pools["cost"].append({"kind": "cost", "at": b["req"], "why": f"cache miss ({b['cause']}): ~{b['lost']:,} tok rewritten, ${b['premium']:.2f} premium", "share": share_of_cost(b["premium"]), "shape": "cache miss"})
    for g in sweep_result["gaps"]:
        if g["seconds"] >= time_floor and g["what"] != "background":  # that work has its own subagent row
            pools["time"].append({"kind": "time", "at": g["req"], "why": f"{fmt_s(g['seconds'])} in one {g['what']} gap", "share": g["seconds"] / active if active else 0, "shape": g["what"]})
    for f in frictions:
        pools["friction"].append({"kind": "friction", "at": f["req"] or 1, "why": f["what"], "share": COST_FLOOR_SHARE * f["weight"], "shape": "friction", "weight": f["weight"]})
    for p in pools.values():
        p.sort(key=lambda m: -m["share"])

    chosen = []

    def take(m):
        if any(m is c["source"] for c in chosen):
            return False
        lo, hi = window(m["at"], m.get("start"))
        if m.get("cap"):
            hi = min(max(m["at"] + LOOK_AHEAD, min(m["cap"], lo + 40)), last_req)
        for c in chosen:
            if c["from"] <= m["at"] <= c["to"]:
                if m["why"] != c["why"] and m["why"] not in c["also"]:
                    c["also"].append(m["why"])
                return False
        chosen.append({**m, "from": lo, "to": hi, "also": [], "source": m})
        return True

    risk = risks[0] if risks else None
    room = MOMENTS_MAX - (1 if risk else 0)
    # One of each kind first, so a heavy session's cost can't crowd out what was cheap but wrong.
    for name in ("cost", "time", "friction"):
        for m in pools[name]:
            if take(m):
                break
        if len(chosen) >= room:
            break
    for m in sorted(pools["cost"] + pools["time"] + pools["friction"], key=lambda m: -m["share"]):
        if len(chosen) >= room:
            break
        take(m)
    if risk:
        lo, hi = window(risk["req"])
        chosen.append({"kind": "risk", "at": risk["req"], "from": lo, "to": hi, "why": f"zero-cost risk `{risk['what']}`: {risk['label']}", "share": 0, "shape": "risk", "source": risk, "also": [f"{len(risks) - 1} more risky calls"] if len(risks) > 1 else []})
    return chosen


# ---------------------------------------------------------------------------
# Output.


def fmt_s(s):
    s = int(s)
    if s < 90:
        return f"{s}s"
    if s < 5400:
        return f"{s // 60}m{s % 60:02d}s"
    return f"{s // 3600}h{s % 3600 // 60:02d}m"


def tok(n):
    return f"{n / 1e6:.2f}M" if n >= 1e6 else f"{n / 1e3:.0f}k" if n >= 1e3 else str(n)


def pct(x, total):
    return f"{100 * x / total:.0f}%" if total else "-"


def table(headers, rows):
    rows = [[str(c) for c in r] for r in rows]
    widths = [max(len(h), *(len(r[i]) for r in rows)) if rows else len(h) for i, h in enumerate(headers)]
    print("  " + "  ".join(h.ljust(w) for h, w in zip(headers, widths)))
    for r in rows:
        print("  " + "  ".join(c.ljust(w) for c, w in zip(r, widths)).rstrip())


def report(args):
    s = load(args.session)
    if not s.requests:
        sys.exit(f"spend: {s.path} has no API requests to analyse (before any /retro)")
    top = args.top
    cap_s = CAP_MINUTES * 60
    costs = [r.costs() for r in s.requests]
    unpriced = sorted({r.model or "?" for r, c in zip(s.requests, costs) if c is None})
    classes = {k: sum(c[k] for c in costs if c) for k in ("input", "read", "write", "output")}
    main_cost = sum(classes.values())
    child_cost = sum(r.cost for c in s.children for r in c.requests)
    total = main_cost + child_cost
    items, busts, compactions, negative = allocate(s)
    calls = call_table(s)
    items_by_call = {i.call_id: i for i in items if i.call_id}
    for i in items:
        if i.kind == "tool":
            c = calls.get(i.call_id)
            i.label = call_label(c["name"], c["input"]) if c else "tool result"
    swept = sweep(s, cap_s)
    b = swept["buckets"]
    active = sum(b[k] for k in b if k != "away")
    subagents = subagent_rows(s, calls)
    turns = turn_rows(s, subagents)
    frictions = friction(s, calls)
    risks = risky_calls(s)

    ts = [e["ts"] for e in s.events if e["ts"]]
    start = datetime.fromtimestamp(min(ts)).strftime("%Y-%m-%d %H:%M") if ts else "?"
    print(f"# Ledger: {s.id} · {s.source} · {tilde(s.cwd)} · from {start} · {len(s.requests)} requests · {len(s.children)} subagents")
    if s.source == "claude-work":
        print("(work profile: paraphrase, never quote)")
    dup = f"{s.records} assistant records → {len(s.requests)} requests" if s.source != "pi" else f"{len(s.requests)} requests"
    print(f"list price, table read {PRICES_READ} · {dup}" + (f" · retro span excluded (${s.excluded_cost:.2f})" if s.cut_ts else ""))
    if unpriced:
        print(f"UNPRICED models, counted as $0: {', '.join(unpriced)}")

    print("\n## Spend")
    print(f"total ${total:.2f}: main ${main_cost:.2f}, subagents ${child_cost:.2f}")
    print(
        f"main by class: read ${classes['read']:.2f} ({pct(classes['read'], main_cost)}, {tok(sum(r.read for r in s.requests))}), "
        f"write ${classes['write']:.2f} ({pct(classes['write'], main_cost)}, {tok(sum(r.w5m for r in s.requests))} 5m, {tok(sum(r.w1h for r in s.requests))} 1h), "
        f"output ${classes['output']:.2f} ({pct(classes['output'], main_cost)}, {tok(sum(r.output for r in s.requests))}, thinking {tok(sum(r.thinking for r in s.requests))} included), "
        f"input ${classes['input']:.2f} ({pct(classes['input'], main_cost)})"
    )
    premium = sum(x["premium"] for x in busts)
    print(f"main allocated: context items ${sum(i.cost for i in items):.2f} (estimated), cache-miss events ${premium:.2f}, output ${classes['output']:.2f}")
    state = (s.cost_state or {}).get("totalCostUSD")
    if state is not None:
        print(f"cost-state ${state:.2f} (whole session, retro included) · unattributed ${state - total - s.excluded_cost:.2f}, never spread over items")
    else:
        print("cost-state: not available")

    print("\n## Time")
    wall = duration(s)
    print(f"wall {fmt_s(wall)}, active {fmt_s(active)} at a {CAP_MINUTES}m cap · nothing credited after the last event")
    print(
        f"model {fmt_s(b['model'])} ({pct(b['model'], active)}) · compaction {fmt_s(b['compaction'])} · tools {fmt_s(b['tool'])} ({pct(b['tool'], active)}) · "
        f"permission wait {fmt_s(b['permission'])} · background {fmt_s(b['background'])} · you engaged {fmt_s(b['engaged'])} ({pct(b['engaged'], active)}) · you away {fmt_s(b['away'])}"
    )
    sens = []
    machine = b["model"] + b["compaction"] + b["tool"] + b["background"]
    for c in CAPS:
        kept = sum(min(g, c * 60) for g in swept["human_gaps"])
        sens.append(f"{c}m {pct(kept, machine + kept)}")
    print(f"your share of the time: raw {pct(swept['raw_human'], machine + swept['raw_human'])}, " + ", ".join(sens))
    think_ms = sum(r.thinking_ms for r in s.requests)
    print(f"thinking: {tok(sum(r.thinking for r in s.requests))} tokens, " + (fmt_s(think_ms / 1000) if think_ms else "time not available"))

    print("\n## Tools (seconds overlap in parallel batches; estimated cost is of their results while present)")
    rows = tool_rows(calls, items_by_call)
    table(
        ("tool", "calls", "errors", "time", "prompted", "result tok", "est $"),
        [(n, r["calls"], r["errors"], fmt_s(r["seconds"]), fmt_s(r["prompted"]) if r["prompted"] else "-", tok(r["tokens"]), f"{r['cost']:.2f}") for n, r in sorted(rows.items(), key=lambda kv: -kv[1]["cost"])[:top]],
    )

    print("\n## Subagents" + ("" if subagents else ": none"))
    if subagents:
        work = sum(a["seconds"] for a in subagents)
        print(f"{fmt_s(work)} of agent time against {fmt_s(wall)} wall (ratio {work / wall:.1f})" if wall else "")
        table(
            ("id", "type", "model", "$", "of which first write", "requests", "tokens", "time", "returned chars", "description"),
            [(a["id"][:10], a["type"], a["model"][:20], f"{a['cost']:.2f}", f"{a['first_write']:.2f}", a["requests"], tok(a["tokens"]), fmt_s(a["seconds"]), a["returned"] if a["returned"] is not None else "?", clip(a["description"], 40)) for a in subagents[:top]],
        )

    print("\n## Skills" + (" (pi: span up to the next prompt)" if s.source == "pi" else ""))
    skills = skill_rows(s)
    if skills:
        table(("skill", "$", "requests"), [(n, f"{r['cost']:.2f}", r["requests"]) for n, r in list(skills.items())[:top]])
    else:
        print("not available")

    print("\n## Context")
    first = s.requests[0].context
    last_big = max(r.context for r in s.requests)
    print(f"first request {tok(first)} (startup context plus the first prompt) · peak {tok(last_big)}")
    if compactions:
        for c in compactions:
            after = len(s.requests) - c["req"]
            saved = max(0, (c["pre"] or 0) - (c["post"] or 0)) * c["r_read"]
            pay = c["rebuild"] / saved if saved else None
            payback = f"pays back after ~{pay:.0f} requests, {after} followed" if pay is not None else f"{after} requests followed"
            print(f"compaction at r{c['req']}: {tok(c['pre'] or 0)} → {tok(c['post'] or 0)}, {fmt_s(c['duration'])}, {c['trigger'] or '?'}; {payback}")
    if negative:
        print(f"context shrank between {negative} request pairs without a boundary; those arrivals are unsized")
    print("largest items, estimated (share while present, not what removing them saves; pressure = tokens × requests):")
    ranked = sorted((i for i in items), key=lambda i: -i.cost)[:top]
    table(
        ("est $", "share", "tokens", "requests", "pressure", "born", "item"),
        [(f"{i.cost:.2f}", pct(i.cost, main_cost), tok(i.size), i.requests, tok(i.size * i.requests), f"r{i.born}", i.label or "tool result") for i in ranked],
    )

    print("\n## Turns (dollars include subagents)")
    table(
        ("#", "$", "requests", "time", "range", "prompt"),
        [(t["n"], f"{t['cost']:.2f}", len(t["requests"]), fmt_s((t["end"] or 0) - (t["ts"] or 0)), f"r{t['from']}-r{t['to']}" if t["from"] else "-", clip(t["text"], 60)) for t in sorted(turns, key=lambda t: -t["cost"])[:top]],
    )

    print("\n## Friction")
    print(f"cache misses {len(busts)} (${premium:.2f} premium) · compactions {len(compactions)} · events {len(frictions)} · risky calls {len(risks)} · ran while idle {sum(e['kind'] == 'idle_work' for e in s.events)}")
    for x in busts:
        if x["premium"] >= 0.01:
            print(f"  r{x['req']}: cache miss, {x['cause']}, ~{tok(x['lost'])} rewritten, ${x['premium']:.2f}")
    for f in sorted(frictions, key=lambda f: -f["weight"])[: top * 2]:
        print(f"  r{f['req']}: {f['what']}")
    if len(frictions) > top * 2:
        print(f"  … {len(frictions) - top * 2} more")
    for r in risks[:top]:
        print(f"  r{r['req']}: risky: {r['label']}")

    print("\n## Model mix")
    mix = {}
    for r in s.requests:
        key = (r.model or "?", r.effort or "-")
        mix[key] = mix.get(key, 0) + 1
    print(" · ".join(f"{m} ({e}): {n}" for (m, e), n in sorted(mix.items(), key=lambda kv: -kv[1])))

    print("\n## Moments")
    moments = select_moments(total, active, items, turns, subagents, swept, frictions, risks, busts, len(s.requests))
    if not moments:
        print("nothing crossed the thresholds")
    for n, m in enumerate(moments, 1):
        agent = f" · agent {m['agent']}" if m.get("agent") else ""
        print(f"{n}. [{m['kind']} · {m['shape']}] r{m['from']}-r{m['to']}{agent}: {m['why']}")
        for a in m["also"][:3]:
            print(f"   also here: {a}")
    print(f"\nRead a moment: python3 <this script> window {s.id} FROM TO")


def window(args):
    s = load(args.session)
    if args.agent:
        child = next((c for c in s.children if c.id.startswith(args.agent)), None)
        if child is None:
            sys.exit(f"spend: no subagent {args.agent} in this session")
        s = child
    if s.source == "claude-work":
        print("(work profile: paraphrase, never quote)")
    names = {}
    req = 0
    out = []
    prompts = 0
    for e in s.events:
        k = e["kind"]
        if k == "request":
            req = e["req"].n
            r = e["req"]
            line = f"[r{req}] context {tok(r.context)} (read {tok(r.read)}, write {tok(r.write)}), output {tok(r.output)}, ${r.cost:.2f}"
        elif k == "prompt":
            prompts += 1
            line = f"[you #{prompts}] {clip(e['text'], 1500)}"
        elif k == "say":
            line = f"[agent] {clip(e['text'], 1200)}"
        elif k == "think":
            line = f"[thinking] {clip(e['text'], 800)}"
        elif k == "call":
            names[e["call_id"]] = e
            line = f"[call] {e['name']}: {clip(json.dumps(e['input']), 300)}"
        elif k == "result":
            c = names.get(e["call_id"]) or {}
            tag = f"denied {e['denial']}" if e["denial"] else ("error" if e["error"] else "result")
            source = f" ({e['source']})" if e["source"] and e["source"] != "config" else ""
            line = f"[{tag}{source}] {c.get('name', '?')}, {e['chars']:,} chars: {clip(e['text'], 300)}"
        elif k == "interrupt":
            line = "[interrupted]"
        elif k == "compact":
            line = f"[compaction] {tok(e.get('pre') or 0)} → {tok(e.get('post') or 0)}"
        elif k == "queued":
            line = "[you queued a message mid-turn]"
        elif k == "hook":
            line = "[a hook prevented continuing]" if e["blocked"] else f"[hook errors: {e['errors']}]"
        elif k == "api_error":
            line = "[API error]"
        else:
            continue
        out.append((max(req, 1), line))
    if args.grep:
        pattern = re.compile(args.grep, re.I)
        for n, line in out:
            if pattern.search(line):
                print(f"r{n}: {clip(line, 200)}")
        return
    lo, hi = args.first, args.last
    lines = [line for n, line in out if lo <= n <= hi]
    if args.max_lines and len(lines) > args.max_lines:
        lines = lines[: args.max_lines] + [f"[… {len(lines) - args.max_lines} more lines; raise --max-lines]"]
    print("\n".join(lines))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)
    r = sub.add_parser("report")
    r.add_argument("session", nargs="?")
    r.add_argument("--top", type=int, default=8, help="rows per section")
    w = sub.add_parser("window")
    w.add_argument("session")
    w.add_argument("first", type=int, nargs="?", default=1)
    w.add_argument("last", type=int, nargs="?", default=10**9)
    w.add_argument("--agent", help="read this subagent's own transcript; its requests are numbered separately")
    w.add_argument("--grep", help="list matching events and their requests instead")
    w.add_argument("--max-lines", type=int, default=200)
    args = p.parse_args()
    {"report": report, "window": window}[args.command](args)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        pass
