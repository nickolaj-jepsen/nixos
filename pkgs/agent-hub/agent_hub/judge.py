"""The one reading of a session, for every agent: what the work is called, what it is
on, and how each turn ended.

The hub reads a digest out of the session's transcript (fields below), renders it, asks
a model through the session's backend, and parses the answer.
The answer comes as `key: value` lines rather than JSON: a missing key means
"unchanged", a malformed line costs only itself, and there is no schema for a small
model to lose its way in.

Digest fields, all optional: `requests` (the person's latest prompts), `files`
(touched), `commands` (each with `(ok)` or `(failed)`), `said` (the turn's closing
words, settle only), `pending` (background jobs not reported back), `repo`,
`branch`, `worth` (whether the turn is worth a model's reading) and `error` (the
turn ended on an error).
"""

import re

from .common import folded

FIELDS = ("label", "doing", "summary", "tags", "state", "did", "ask", "reply")
TURN_STATES = ("done", "blocked", "failed", "waiting")
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
SAID_CHARS = 1500

SYSTEM = f"""You keep a coding session's identity current for the person working in it.
Answer with exactly these eight lines, in this order, and nothing else:
label: 2-6 lowercase words naming what the work is about
doing: at most 8 words for the step in flight, or empty
summary: one sentence of at most 20 words about the session so far
tags: up to three of {" ".join(TAGS)}
state: done, blocked, failed or waiting for the assistant turn, or empty
did: one sentence of at most 20 words about what the assistant turn did, or empty
ask: what the assistant turn needs from the person, or empty
reply: what the person would most likely type to answer ask, or empty

- The label names the work, never that you agreed to something.
- Repeat the current label word for word when the work has not moved on.
- doing names the step, not the subject: "stuck on the retry test", not "auth work".
- The branch is a hint about the work, never the label on its own.
- Fill state, did, ask and reply only from the assistant turn below. Leave all four
  empty when there is no such turn.
- state: done when the turn finished what was asked, blocked when it waits on a
  decision or answer from the person, failed when it gave up or says the work does
  not work yet, waiting when it ended only to wait for its own background jobs and
  carries on by itself when they report back. A turn with an ask is blocked.
- ask is a request, not a summary: "keep the old fixture?" not "asked about the fixture".
  Leave it empty when the turn asks for nothing.
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
        lines.append(f"files touched: {', '.join(digest['files'])}")
    if digest.get("commands"):
        lines.append(f"commands: {'; '.join(digest['commands'])}")
    if settle and digest.get("pending"):
        lines.append(f"background jobs started that have not reported back: {digest['pending']}")
    lines.append("requests:")
    lines.extend(f"- {request}" for request in digest.get("requests") or [])
    said = digest.get("said") if settle else None
    if said:
        lines.append(f"assistant said: {folded(said)[-SAID_CHARS:]}")
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


def heuristic(digest):
    """How the turn ended by its closing words alone: a question in its last paragraphs
    is an ask, and words of waiting with jobs still out keep it working."""
    final = CODE_BLOCK.sub("", digest.get("said") or "").strip()
    paragraphs = [folded(MARKDOWN.sub("", p)) for p in re.split(r"\n\s*\n", final)]
    paragraphs = [p for p in paragraphs if p]
    sentences = re.split(r"(?<=[.?!])\s+", " ".join(paragraphs[-2:]))
    asks = [s for s in sentences if s.endswith("?")]
    first = re.split(r"(?<=[.?!])\s+", paragraphs[0])[0] if paragraphs else ""
    pending = int(digest.get("pending") or 0)
    if digest.get("error"):
        state = "failed"
    else:
        state = "blocked" if asks else "done"
    return {
        "state": state,
        "ask": asks[-1][:MAX_ASK] if asks and state == "blocked" else "",
        "summary": first[:MAX_SUMMARY],
        "jobs": pending if WAITS.search(final) else 0,
    }


def outcome(fields, guess, digest):
    """How the turn ended, by the model's reading where it gave one and the guess elsewhere."""
    pending = int(digest.get("pending") or 0)
    state = fields.get("state") or guess["state"]
    ask = fields["ask"] if "ask" in fields else guess["ask"]
    if digest.get("error"):
        state = "failed"
    # An open question is the person's turn whatever the model called it.
    elif ask:
        state = "blocked"
    waiting = state == "waiting"
    if waiting:
        jobs = max(pending, 1)
    else:
        # Without the model's word, the closing words say whether it waits on its jobs.
        jobs = 0 if "state" in fields else guess["jobs"]
    return {
        "state": "done" if waiting else state,
        "ask": ask if state == "blocked" else "",
        "reply": fields.get("reply", "") if state == "blocked" else "",
        "summary": fields.get("did") or guess["summary"],
        "jobs": jobs,
    }
