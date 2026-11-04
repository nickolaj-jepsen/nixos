"""What counts as a secret, and how a match is replaced.

Matching happens on decoded JSON strings, never on raw file bytes: a private key
in a transcript is one string with `\n` escapes in it, and the base64 that fills
these logs produces constant false positives (`AKIABAAAAAAAAUAADAAA` is not an
AWS key). Every pattern therefore anchors on both sides.
"""

from __future__ import annotations

import hashlib
import re

# Keys whose values are opaque replay or binary payloads: rewriting them would
# break the session (thinking signatures are replayed to the provider verbatim)
# and they cannot hold transcript text anyway.
OPAQUE_KEYS = frozenset({"thinkingSignature", "signature", "encrypted_content", "data"})

# Left and right context that means "this is inside a blob, not a token". `=` is
# allowed on the left so `TOKEN=ghp_...` still matches; it only ever ends a
# base64 chunk, so keeping it on the right is what anchors a match out of one.
_NOT_BLOB = r"(?<![A-Za-z0-9+/_-])"
_NOT_BLOB_END = r"(?![A-Za-z0-9+/=_-])"

# Complete PEM private keys, multi-line. The body is matched lazily up to the
# END line; a truncated read (no END) is handled separately, below.
_PEM = re.compile(
    r"-----BEGIN ((?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?)-----"
    r".*?"
    r"-----END \1-----",
    re.S,
)
_PEM_HEADER = re.compile(r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----")
# Key material, not prose: PEM bodies are long base64 lines, so a short word
# after a truncated header stays where it is.
_KEY_BODY = re.compile(r"\s*(?:[A-Za-z0-9+/=]{16,}[ \t]*(?:\r?\n|\Z))+")

PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("age-key", re.compile(r"AGE-SECRET-KEY-1[0-9A-Z]{58}")),
    ("github-token", re.compile(_NOT_BLOB + r"(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}" + _NOT_BLOB_END)),
    ("github-pat", re.compile(_NOT_BLOB + r"github_pat_[A-Za-z0-9_]{82}" + _NOT_BLOB_END)),
    ("gitlab-token", re.compile(_NOT_BLOB + r"glpat-[A-Za-z0-9_-]{20,}" + _NOT_BLOB_END)),
    ("anthropic-key", re.compile(_NOT_BLOB + r"sk-ant-(?:api|oat|sid)[0-9]{2}-[A-Za-z0-9_-]{80,}" + _NOT_BLOB_END)),
    ("openai-key", re.compile(_NOT_BLOB + r"(?:sk-proj-|sk-svcacct-)[A-Za-z0-9_-]{60,}" + _NOT_BLOB_END)),
    ("openai-key", re.compile(_NOT_BLOB + r"sk-[A-Za-z0-9]{48}" + _NOT_BLOB_END)),
    ("slack-token", re.compile(_NOT_BLOB + r"xox[baprs]-[A-Za-z0-9-]{10,}" + _NOT_BLOB_END)),
    ("aws-key-id", re.compile(_NOT_BLOB + r"(?:AKIA|ASIA)[0-9A-Z]{16}" + _NOT_BLOB_END)),
    ("aws-secret", re.compile(r"(?i)aws_secret_access_key\W{0,4}([A-Za-z0-9/+=]{40})")),
    # A JWT's first two segments are base64 of JSON, so they start with `eyJ`;
    # requiring that on both keeps prose and blobs out.
    ("jwt", re.compile(_NOT_BLOB + r"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}" + _NOT_BLOB_END)),
)

# Only the captured group is secret in these: the name around it is not.
_GROUPED = frozenset({"aws-secret"})

# Most strings in a transcript are prose; this is the cheap test that keeps the
# full rule set off them. A substring that no rule can be part of cannot match.
_GUARD = re.compile(
    r"-----|AGE-SECRET-KEY-1|gh[pousr]_|github_pat_|glpat-|sk-|xox[baprs]-|A[KS]IA|eyJ|aws_secret",
    re.I,
)

# Shorter values are too likely to appear as ordinary text; `--values-from` is
# for passwords and other one-off secrets, so it is still worth some slack.
MIN_LITERAL_LEN = 6


def fingerprint(value: str) -> str:
    """Stable 8-hex tag for a value, so occurrences stay correlated without it."""
    return hashlib.sha256(value.encode()).hexdigest()[:8]


def placeholder(rule: str, value: str) -> str:
    return f"[redacted:{rule}:{fingerprint(value)}]"


def _redact_pem(text: str, hits: dict[str, int], samples: dict[str, str] | None = None) -> str:
    def note(value: str) -> str:
        hits["private-key"] = hits.get("private-key", 0) + 1
        token = placeholder("private-key", value)
        if samples is not None:
            samples.setdefault("private-key", token)
        return token

    def whole(match: re.Match[str]) -> str:
        return note(match.group(0))

    text = _PEM.sub(whole, text)

    # A key whose END line never made it into the transcript (a `head -20` of a
    # key file, or an error before the rest was read). Take the header plus the
    # base64 that follows it, and stop at the first line that cannot be key
    # material, so the rest of the entry survives.
    while True:
        match = _PEM_HEADER.search(text)
        if match is None:
            return text
        end = match.end()
        body_match = _KEY_BODY.match(text, end)
        stop = body_match.end() if body_match else end
        text = text[: match.start()] + note(text[match.start() : stop]) + text[stop:]


def redact_text(
    text: str,
    literals: dict[str, str] | None = None,
    samples: dict[str, str] | None = None,
) -> tuple[str, dict[str, int]]:
    """Replace every secret in `text`.

    Returns the new text and how many matches each rule made. `literals` maps
    secret values to the rule name to record for them (`--values-from`), and
    `samples` collects one placeholder per rule for reporting. Matching is
    idempotent: placeholders contain none of the patterns.
    """
    hits: dict[str, int] = {}
    if _GUARD.search(text) is None and not literals:
        return text, hits
    text = _redact_pem(text, hits, samples)

    for rule, pattern in PATTERNS:
        def replace(match: re.Match[str], rule: str = rule) -> str:
            value = match.group(1) if rule in _GROUPED else match.group(0)
            hits[rule] = hits.get(rule, 0) + 1
            token = placeholder(rule, value)
            if samples is not None:
                samples.setdefault(rule, token)
            if rule in _GROUPED:
                start = match.start(1) - match.start(0)
                whole = match.group(0)
                return whole[:start] + token + whole[start + len(value) :]
            return token

        text = pattern.sub(replace, text)

    # Literals last: they are the least specific, and the patterns above already
    # took what they could describe better.
    for value, rule in (literals or {}).items():
        if len(value) < MIN_LITERAL_LEN or value not in text:
            continue
        count = text.count(value)
        hits[rule] = hits.get(rule, 0) + count
        token = placeholder(rule, value)
        if samples is not None:
            samples.setdefault(rule, token)
        text = text.replace(value, token)

    return text, hits
