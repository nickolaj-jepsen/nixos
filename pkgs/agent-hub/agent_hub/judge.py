"""The one reading of a session, for every agent: what the work is called, what it is
on, and how each turn ended.

The hub reads a digest out of the session's transcript (fields below), renders it, asks
a model through the session's backend, and parses the answer.
The answer comes as `key: value` lines rather than JSON: a missing key means
"unchanged", a malformed line costs only itself, and there is no schema for a small
model to lose its way in.

Digest fields, all optional: `requests` (the person's latest prompts), `files` (touched
in the latest turn), `commands` (that turn's, each with `(ok)` or `(failed)`), `said` (its
closing words, settle only), `peer` (it answered another session rather than the person),
`pending` (jobs in flight that may be a server left running),
`agents` (agent work in flight, which will report back), `doing` (what that work is),
`repo`, `branch` and `error` (the turn ended on an error).

The gate: only a turn whose closing words hold a question or a request can need a reply.
The model reads every turn and may demote such a candidate to done; it can't raise one,
and without its word the candidate stands. `failed` comes only from the agent's own error.
"""

import hashlib
import re

from .common import BLOCK_MAX, folded, shown_block

FIELDS = ("label", "doing", "summary", "tags", "state", "did", "ask", "kind", "reply")
TURN_STATES = ("done", "blocked", "waiting")
# What an ask wants of you, as a row's tag says it.
ASK_KINDS = ("decide", "info", "approve", "do something")
TAGS = ("bugfix", "feature", "refactor", "test", "docs", "deps", "ci", "perf", "chore")
MAX_LABEL = 40
MAX_DOING = 32
MAX_SUMMARY = 120
MAX_ASK = 110
MAX_REPLY = 240
MAX_TAGS = 3
# Headroom for the lines, not a target: a reasoning model thinks before it answers, and
# a cap below that thinking returns no text at all.
MAX_TOKENS = 1024
SAID_CHARS = 6000
# Background task types that always report back; a shell task can be a server left running.
AGENT_TASKS = ("subagent", "workflow", "teammate", "monitor", "cloud session")
MAX_TASK_LINE = 80

SYSTEM = f"""You keep a coding session's identity current for the person working in it.
Answer with exactly these nine lines, in this order, and nothing else:
label: 2-6 lowercase words naming what the work is about
doing: at most 8 words for the step in flight, or empty
summary: one sentence of at most 20 words about the session so far
tags: up to three of {" ".join(TAGS)}
state: done, blocked or waiting for the assistant turn, or empty
did: one sentence of at most 20 words about what the assistant turn did, or empty
ask: what the assistant turn needs from the person, or empty
kind: one of {", ".join(ASK_KINDS)} for what ask wants, or empty
reply: what the person would most likely type to answer ask, or empty

- The label names the work, never that you agreed to something.
- Repeat the current label word for word when the work has not moved on.
- doing names the step, not the subject: "stuck on the retry test", not "auth work".
- The branch is a hint about the work, never the label on its own.
- Fill state, did, ask, kind and reply only from the assistant turn below. Leave all five
  empty when there is no such turn.
- state: blocked only when the turn puts a real question or request to the person and
  can't proceed without their answer, wherever in its message that comes. A list of
  questions waiting on answers is blocked even if the message ends on something else. An
  offer to commit, push, deploy or switch that waits on their word is blocked, and so is
  asking them to do something and report back ("after the reboot, tell me").
- state: done when the turn finished, including when it reports a problem. Optional
  extras ("I could also..."), a pointer at the person's next step ("next: run the tests"),
  an offer that only applies if they want it ("if you'd rather X, tell me") and a
  rhetorical question are done.
- state: waiting when it ended only to wait for its own background jobs and carries on
  by itself when they report back.
- ask is a request, not a summary: "keep the old fixture?" not "asked about the fixture".
  Leave it empty unless state is blocked.
- kind: decide when they choose between ways forward, info when the agent lacks a fact only
  they have, approve when it has one action ready and waits for a yes, do something when
  they have to act themselves, such as rebooting or testing.
- reply predicts what the person would type, not what you think they should say:
  their words, their length and their tone, as in the requests above. Leave it
  empty when you cannot tell which way they would answer.
- No quotes, no preamble, no commentary, no other lines."""

# Tolerates a model that answers in a list or bolds its keys, which small ones do.
LINE = re.compile(r"^[\s>*#-]*\**\s*(" + "|".join(FIELDS) + r")\s*\**\s*:\s*\**\s*(.*?)\s*\**\s*$", re.I)
QUOTES = "\"'`“”‘’"
EMPTY = ("", "empty", "none", "-", "n/a")
CODE_BLOCK = re.compile(r"```.*?```", re.S)
MARKDOWN = re.compile(r"[*`#>]+")
# Words of a turn that ended to wait for its own jobs; a server it left running for you says none of them.
WAITS = re.compile(r"\b(wait(ing)? (for|on|until)|(i'll|i will) (be notified|check back)|once (it|they)|when (it|they) (finish|complete|report))", re.I)
# Words of a turn that asks without a question mark.
REQUEST = re.compile(
    r"\b(let me know|tell me|your call|please (confirm|review|approve|decide|check|try)|confirm (that|whether|the)"
    r"|say (if|whether|go)|up to you|waiting (for|on) your|needs? your|i need you|you['’]ll need to|once you['’]ve)\b",
    re.I,
)
CLOSERS = ")]\"'”’*_"
# Names the prompt and the rule a verdict came from, so a log line and an eval can be told apart.
VERSION = hashlib.sha256("\n".join((SYSTEM, WAITS.pattern, REQUEST.pattern)).encode()).hexdigest()[:8]


def render(digest, identity, settle):
    """The prompt the model reads: the digest, and what the session is already called
    so the model can repeat it, extend it or re-tag it."""
    repo, branch = digest.get("repo"), digest.get("branch")
    lines = [f"repo: {repo}" + (f" · branch: {branch}" if branch else "")] if repo else []
    if identity.get("label"):
        lines.append(f"current label: {identity['label']}")
    if identity.get("summary"):
        lines.append(f"previous summary: {identity['summary']}")
    if identity.get("tags"):
        lines.append(f"tags so far: {', '.join(identity['tags'])}")
    if digest.get("files"):
        lines.append(f"files touched in the latest turn: {', '.join(digest['files'])}")
    if digest.get("commands"):
        lines.append(f"commands in the latest turn: {'; '.join(digest['commands'])}")
    if settle and digest.get("pending"):
        lines.append(f"background jobs started that have not reported back: {digest['pending']}")
    if digest.get("peer"):
        lines.append("this assistant turn answered another agent session, not the person: "
                     "it is blocked only if it puts something new to the person")
    lines.append("requests:")
    lines.extend(f"- {request}" for request in digest.get("requests") or [])
    said = digest.get("said") if settle else None
    if said:
        lines.append(f"assistant said: {clipped(folded(said))}")
    return "\n".join(lines)


def strip_quotes(text):
    return text.strip(QUOTES).strip()


def parse(text):
    """The fields in a model's answer; a key it left out is absent, so the caller keeps
    what it had. `doing` and `ask` may be empty, which clears them."""
    fields = {}
    for line in str(text).splitlines():
        match = LINE.match(line)
        if not match:
            continue
        key, value = match.group(1).lower(), strip_quotes(folded(match.group(2)))
        if value.lower() in EMPTY:
            value = ""
        if key == "label":
            if value:
                fields["label"] = value
        elif key == "doing":
            fields["doing"] = value[:MAX_DOING]
        elif key in ("summary", "did"):
            if value:
                fields[key] = value[:MAX_SUMMARY]
        elif key == "state":
            if value.lower() in TURN_STATES:
                fields["state"] = value.lower()
        elif key == "ask":
            fields["ask"] = value[:MAX_ASK]
        elif key == "kind":
            if value.lower() in ASK_KINDS:
                fields["kind"] = value.lower()
        elif key == "reply":
            fields["reply"] = value[:MAX_REPLY]
        elif key == "tags":
            tags = [re.sub(r"[^a-z0-9-]", "", tag.lower()) for tag in re.split(r"[,\s]+", value)]
            fields["tags"] = [tag for tag in tags if tag][:MAX_TAGS]
    return fields


def clean_label(raw):
    """A model's label as a name: one line, no quotes, no emoji or stray brackets (they
    cost two columns and read as decoration), cut at a word."""
    first = re.sub(r"^(label|session|task)\s*:\s*", "", folded(raw), flags=re.I)
    text = re.sub(r"^[\"'`]+|[\"'`.,;:]+$", "", first)
    text = re.sub(r"[^\w '\-/]", "", text).replace("_", "")
    text = " ".join(text.split())
    if len(text) <= MAX_LABEL:
        return text
    cut = text[:MAX_LABEL]
    space = cut.rfind(" ")
    return (cut[:space] if space > 20 else cut).strip() + "…"


def clipped(text):
    """Long closing words as the model reads them: an ask can sit anywhere in a list of them."""
    if len(text) <= SAID_CHARS:
        return text
    half = SAID_CHARS // 2
    return f"{text[:half]} […] {text[-half:]}"


def heuristic(digest):
    """How the turn ended by its closing words alone: a question or a request anywhere in them
    is an ask (the gate's candidate), and words of waiting with jobs still out keep it working.
    A message can end on something else after its questions, and the model can only demote."""
    final = CODE_BLOCK.sub("", digest.get("said") or "").strip()
    paragraphs = [folded(MARKDOWN.sub("", p)) for p in re.split(r"\n\s*\n", final)]
    paragraphs = [p for p in paragraphs if p]
    sentences = re.split(r"(?<=[.?!])\s+", " ".join(paragraphs))
    asks = [s for s in sentences if s.rstrip(CLOSERS).endswith("?")] or [s for s in sentences if REQUEST.search(s)]
    first = re.split(r"(?<=[.?!])\s+", paragraphs[0])[0] if paragraphs else ""
    pending = int(digest.get("pending") or 0)
    if digest.get("error"):
        state = "failed"
    else:
        state = "blocked" if asks else "done"
    return {
        "state": state,
        "ask": asks[-1][:MAX_ASK] if asks else "",
        "summary": first[:MAX_SUMMARY],
        "jobs": pending if WAITS.search(final) else 0,
    }


def with_ending(found, ending):
    """The digest with what the agent itself said of the turn's end (`turn-end`), which beats
    its transcript: a transcript can lag behind the turn, and only the agent knows its jobs."""
    tasks = ending.get("tasks") or []
    agents = [t for t in tasks if t["type"] in AGENT_TASKS]
    shells = len(tasks) - len(agents)
    described = [folded(t.get("description") or "") for t in (agents or tasks)]
    described = [d for d in described if d]
    doing = described[0][:MAX_TASK_LINE] if described else ""
    if doing and len(tasks) > 1:
        doing += f" +{len(tasks) - 1}"
    return {
        **found,
        "said": ending.get("said") or found.get("said") or "",
        "agents": len(agents),
        "pending": max(shells, int(ending.get("pending") or 0)),
        "doing": doing,
        "tasks": [d[:MAX_TASK_LINE] for d in described],
        "error": bool(ending.get("error")),
    }


def died(reason):
    """A turn the agent says died, as an API error ends one."""
    return {"state": "failed", "ask": "", "reply": "", "summary": reason[:MAX_SUMMARY], "jobs": 0, "doing": "",
            "source": "error", "chars": 0}


def outcome(fields, guess, digest):
    """How the turn ended: the gate over the candidate in `guess`, by the model's word in
    `fields` when it gave one. The model's `waiting` only counts with jobs to wait on."""
    word = fields.get("state")
    agents, pending = int(digest.get("agents") or 0), int(digest.get("pending") or 0)
    if digest.get("error"):
        state = "failed"
    elif guess["ask"] and word not in ("done", "waiting"):
        state = "blocked"
    else:
        state = "done"
    if state != "done":
        jobs = 0
    elif agents:
        jobs = agents + pending
    elif word:
        jobs = pending if word == "waiting" else 0
    else:
        # Without the model's word, the closing words say whether it waits on its jobs.
        jobs = guess["jobs"]
    return {
        "state": state,
        "ask": (fields.get("ask") or guess["ask"])[:MAX_ASK] if state == "blocked" else "",
        "kind": fields.get("kind", "") if state == "blocked" else "",
        "reply": fields.get("reply", "") if state == "blocked" else "",
        "summary": fields.get("did") or guess["summary"],
        "jobs": jobs,
        "doing": digest.get("doing") or "" if jobs else "",
        "tasks": digest.get("tasks") or [] if jobs else [],
        # What the popout shows of a turn that needs you, in the agent's own words.
        "said": shown_block((digest.get("said") or "")[-BLOCK_MAX:])[0] if state == "blocked" else "",
        # For the journal: what settled it and how much it read, never the words themselves.
        "source": "error" if digest.get("error") else "model" if word else "words",
        "chars": len(digest.get("said") or ""),
        # For the work log: what the verdict was made of.
        "candidate": bool(guess["ask"]),
        "word": word or "",
    }
