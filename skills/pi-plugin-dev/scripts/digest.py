#!/usr/bin/env python3
"""Flatten a pi session file into the facts a plugin author needs.

Replays the system messages to reconstruct the prompt sections and the tool
declarations the model was actually offered, pairs tool calls with their
results, and totals usage. Read-only: nothing here talks to pi.

Usage: digest.py SESSION.jsonl [--json] [--width N]
Prints sections on stdout. --json prints one aggregate object instead.
Text is collapsed and truncated to --width (default 96) columns.
"""

import argparse
import json
import os
import re
import sys

ZERO = {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 0, "cost": 0.0}


def collapse(text):
    return re.sub(r"\s+", " ", text).strip()


def short(text, width):
    text = collapse(text)
    return text if len(text) <= width else text[: width - 1] + "…"


def content_text(content):
    """Model-facing text of a message's content, which is a string or blocks."""
    if isinstance(content, str):
        return content
    parts = []
    for block in content or []:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text":
            parts.append(block.get("text", ""))
        elif block.get("type") == "thinking":
            parts.append(block.get("thinking", ""))
    return " ".join(parts)


def read_entries(path):
    entries, bad = [], 0
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                bad += 1
    return entries, bad


def loadout(entries):
    """Replay system messages into the current prompt sections and tools.

    Sections patch by name, a null value removes one, and tool declarations
    arrive as toolsAdded / toolsRemoved.
    """
    sections, tools = {}, {}
    for entry in entries:
        if entry.get("type") == "compaction":
            checkpoint = entry.get("systemMessage") or {}
            sections = dict(checkpoint.get("sections") or {})
            tools = {tool.get("name", "?"): tool for tool in checkpoint.get("toolsAdded") or []}
            continue
        message = entry.get("message") or {}
        if entry.get("type") != "message" or message.get("role") != "system":
            continue
        for name, value in (message.get("sections") or {}).items():
            if value is None:
                sections.pop(name, None)
            else:
                sections[name] = value
        for tool in message.get("toolsAdded") or []:
            tools[tool.get("name", "?")] = tool
        for tool in message.get("toolsRemoved") or []:
            tools.pop(tool.get("name"), None)
    return sections, tools


def build(path):
    entries, bad = read_entries(path)
    header = next((e for e in entries if e.get("type") == "session"), {})
    sections, tools = loadout(entries)
    usage = dict(ZERO)
    model = provider = None
    thinking = None
    timeline = []

    def add_usage(block):
        if not block:
            return
        usage["input"] += block.get("input", 0) or 0
        usage["output"] += block.get("output", 0) or 0
        usage["cacheRead"] += block.get("cacheRead", 0) or 0
        usage["cacheWrite"] += block.get("cacheWrite", 0) or 0
        usage["totalTokens"] += block.get("totalTokens", 0) or 0
        usage["cost"] += ((block.get("cost") or {}).get("total", 0)) or 0

    for index, entry in enumerate(entries, 1):
        kind = entry.get("type")
        if kind == "model_change":
            provider, model = entry.get("provider"), entry.get("modelId")
            timeline.append((index, "model", f"{provider}/{model}"))
        elif kind == "thinking_level_change":
            thinking = entry.get("thinkingLevel")
            timeline.append((index, "thinking", f"level={thinking}"))
        elif kind == "usage":
            add_usage(entry.get("usage"))
            timeline.append((index, "usage", f"kind={entry.get('kind')}"))
        elif kind == "compaction":
            add_usage(entry.get("usage"))
            timeline.append((index, "compaction", f"{entry.get('tokensBefore', '?')} tokens in, keep from {entry.get('firstKeptEntryId')}"))
        elif kind == "branch_summary":
            add_usage(entry.get("usage"))
            timeline.append((index, "branch", short(entry.get("summary", ""), 80)))
        elif kind == "custom":
            timeline.append((index, "custom", f"{entry.get('customType')} {short(json.dumps(entry.get('data')), 70)}"))
        elif kind == "custom_message":
            timeline.append((index, "inject", f"{entry.get('customType')} {short(content_text(entry.get('content')), 70)}"))
        elif kind == "label":
            timeline.append((index, "label", f"{entry.get('label')!r} on {entry.get('targetId')}"))
        elif kind == "context_edit":
            state = "omitted" if entry.get("replacement") is None else "replaced"
            timeline.append((index, "edit", f"{entry.get('targetId')} {state}"))
        elif kind == "message":
            message = entry.get("message") or {}
            role = message.get("role")
            if role == "system":
                continue
            if role == "user":
                timeline.append((index, "user", short(content_text(message.get("content")), 80)))
            elif role == "toolResult":
                status = "ERROR" if message.get("isError") else "ok"
                text = content_text(message.get("content"))
                timeline.append((index, f"result {message.get('toolName', '?')}", f"{status} {len(text)}B  {short(text, 70)}"))
            elif role == "assistant":
                add_usage(message.get("usage"))
                blocks = message.get("content") or []
                if isinstance(blocks, str):
                    blocks = [{"type": "text", "text": blocks}]
                for block in blocks:
                    if not isinstance(block, dict):
                        continue
                    if block.get("type") == "toolCall":
                        args = short(json.dumps(block.get("arguments")), 70)
                        timeline.append((index, f"call {block.get('name', '?')}", args))
                    elif block.get("type") == "text":
                        timeline.append((index, "text", short(block.get("text", ""), 80)))
                    elif block.get("type") == "thinking":
                        timeline.append((index, "thinking", short(block.get("thinking", ""), 60)))
                if not blocks:
                    timeline.append((index, "assistant", "empty"))
                stop = message.get("stopReason")
                if stop and stop not in ("stop", "toolUse"):
                    timeline.append((index, "stop", str(stop)))
            else:
                timeline.append((index, role or "?", short(content_text(message.get("content")), 60)))

    return {
        "session": {
            "id": header.get("id"),
            "version": header.get("version"),
            "cwd": header.get("cwd"),
            "file": path,
            "entries": len(entries),
            "unparsed": bad,
        },
        "model": {"provider": provider, "model": model, "thinking": thinking},
        "prompt": {"sections": {k: len(v) for k, v in sections.items()}},
        "tools": [
            {"name": name, "description": short(tool.get("description", ""), 60)}
            for name, tool in sorted(tools.items())
        ],
        "timeline": [{"at": i, "kind": k, "detail": d} for i, k, d in timeline],
        "usage": usage,
    }


def render(data, width):
    session = data["session"]
    out = [f"session  {session['id']}  v{session['version']}  cwd={session['cwd']}"]
    if session["unparsed"]:
        out.append(f"         {session['unparsed']} unparsable lines skipped")
    model = data["model"]
    out.append(f"model    {model['provider']}/{model['model']}  thinking={model['thinking']}")

    sections = data["prompt"]["sections"]
    if sections:
        total = sum(sections.values())
        out.append(f"prompt   {len(sections)} sections  {total} chars")
        for name, size in sorted(sections.items(), key=lambda kv: -kv[1]):
            out.append(f"  {name:<16} {size}")
    else:
        out.append("prompt   no system message: nothing declared yet")

    tools = data["tools"]
    out.append(f"tools    {len(tools)} declared")
    for tool in tools:
        out.append(f"  {tool['name']:<16} {tool['description']}")

    out.append(f"timeline {len(data['timeline'])} steps")
    for step in data["timeline"]:
        out.append(f"  {step['at']:>3} {step['kind']:<16} {short(step['detail'], width)}")

    usage = data["usage"]
    out.append(
        "usage    in={input} out={output} cache_read={cacheRead} cache_write={cacheWrite} "
        "tokens={totalTokens} cost=${cost:.4f}".format(**usage)
    )
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description="Flatten a pi session file.")
    parser.add_argument("session", help="path to a .jsonl session file")
    parser.add_argument("--json", action="store_true", help="print one aggregate object")
    parser.add_argument("--width", type=int, default=96, help="detail width in columns")
    args = parser.parse_args()
    try:
        data = build(args.session)
    except OSError as error:
        print(f"digest.py: {error}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(data, indent=2))
    else:
        print(render(data, args.width))
    return 0


if __name__ == "__main__":
    # Line buffered so `digest.py | head` sees output before the pipe closes.
    sys.stdout.reconfigure(line_buffering=True)
    try:
        sys.exit(main())
    except BrokenPipeError:
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        sys.exit(0)
