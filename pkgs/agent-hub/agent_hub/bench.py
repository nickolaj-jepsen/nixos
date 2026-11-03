"""Measuring the gate on your own turns.

`agent-hub label` shows you past turn endings with the hub's verdict hidden, and asks whether
the bar should have called you and whether the model's `did` line is accurate. `agent-hub eval`
replays the current gate over those answers and prints how close it comes to its targets.

Labels hold ids and answers, never transcript text. A model call runs as the session's own
profile, so a work transcript stays on the work account. A replay knows less than the live gate
did: not the jobs still out when the turn ended, nor the repo and branch.

Only the unflagged turns can show an ask the regex missed, since the model can only demote.
"""

import math
import os
import random
import shutil
import subprocess
import sys
import tempfile
import time
from collections import Counter, deque
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

from . import claude, judge, pi, worklog
from .common import json_lines, log_path, shown_block

FLAGGED = 35
UNFLAGGED = 15
RECENT_DAYS = 30
# So one long session can't be the whole sample.
SESSION_MAX = 3
TARGET_RECALL = 0.95
TARGET_PRECISION = 0.80
TIMEOUT = 90
WORKERS = 4
SHOWN_CHARS = 6000
PI_ARGS = ["-p", "--no-session", "--no-tools", "--no-skills", "--no-context-files", "--no-mcp", "--model", "vm/flash"]


def labels_path(cfg):
    return Path(cfg["state"]).expanduser().parent / "labels.jsonl"


def read_labels(path):
    try:
        return list(json_lines(path))
    except OSError:
        return []


def sources(home=None):
    """Recent transcripts as buckets of `{agent, profile, path}`, one per agent and profile, so
    the sample takes from each however much the others hold."""
    home = Path(home or Path.home())
    cutoff = time.time() - RECENT_DAYS * 86_400

    def recent(paths, agent, profile):
        found = []
        for path in paths:
            try:
                if path.stat().st_mtime >= cutoff:
                    found.append({"agent": agent, "profile": profile, "path": str(path)})
            except OSError:
                continue
        return found

    buckets = [
        recent((home / ".claude" / "projects").glob("*/*.jsonl"), "claude", None),
        recent((home / ".claude-work" / "projects").glob("*/*.jsonl"), "claude", str(home / ".claude-work")),
        recent((home / ".pi" / "agent" / "sessions").rglob("*.jsonl"), "pi", None),
    ]
    return [bucket for bucket in buckets if bucket]


def read_turns(agent, path):
    """Every turn of a transcript, or none when it can't be read."""
    try:
        if agent == "pi":
            entries, header = pi.read_entries(path)
            return pi.turns(entries, None, header.get("cwd"))[0]
    except OSError:
        return []
    return claude.turns(path) or []


def endings(source):
    """A transcript's turns that can be judged: yours, finished, with closing words."""
    return [{**turn, **source} for turn in read_turns(source["agent"], source["path"])
            if turn.get("said") and turn.get("id") and not turn.get("peer")]


def flagged(turn):
    return bool(judge.heuristic(turn)["ask"])


def candidates(buckets, labels, rng, wanted):
    """Endings not labelled yet, a transcript at a time and taking turns between buckets.
    `wanted(is_flagged)` says whether that kind is still needed, and is asked as each is reached."""
    seen = {(line.get("path"), line.get("turn")) for line in labels}
    per_session = Counter(line.get("path") for line in labels)
    queues = [rng.sample(bucket, len(bucket)) for bucket in buckets]
    while any(queues):
        for queue in queues:
            if not queue:
                continue
            if not (wanted(True) or wanted(False)):
                return
            source = queue.pop()
            found = [turn for turn in endings(source) if (turn["path"], turn["id"]) not in seen]
            rng.shuffle(found)
            room = SESSION_MAX - per_session[source["path"]]
            for turn in found:
                if room <= 0:
                    break
                is_flagged = flagged(turn)
                if wanted(is_flagged):
                    room -= 1
                    yield {**turn, "flagged": is_flagged}


def ask_model(turn, cfg):
    """The model's reading of a past turn: its fields, or {} when the call failed. Each call
    runs apart from any session, with the hub off, and as the session's profile."""
    prompt = judge.render(turn, {}, True)
    env = dict(os.environ, AGENT_HUB="off", AGENT_HUB_HIDDEN="1")
    if turn["agent"] == "pi":
        exe = cfg.get("pi") or shutil.which("pi")
        argv = [exe, *PI_ARGS, "--system-prompt", judge.SYSTEM]
    else:
        exe = cfg.get("claude") or shutil.which("claude")
        argv = [exe, *claude.JUDGE_ARGS, "--system-prompt", judge.SYSTEM]
        env.pop("CLAUDE_CONFIG_DIR", None)
        if turn.get("profile"):
            env["CLAUDE_CONFIG_DIR"] = turn["profile"]
    if not exe:
        return {}
    try:
        with tempfile.TemporaryDirectory(prefix="agent-hub-bench-") as cwd:
            done = subprocess.run(argv, input=prompt, capture_output=True, text=True, timeout=TIMEOUT, env=env, cwd=cwd)
    except (OSError, subprocess.TimeoutExpired):
        return {}
    return judge.parse(done.stdout) if done.returncode == 0 else {}


def verdict(turn, fields):
    """What the gate makes of a past turn, given the model's `fields` ({} for the words alone)."""
    return judge.outcome(fields, judge.heuristic(turn), turn)


def read_key(stream):
    """One keypress at a terminal, one line otherwise; empty at the end of the input."""
    if not stream.isatty():
        return stream.readline().strip().lower()[:1]
    import termios
    import tty

    fd = stream.fileno()
    saved = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        return stream.read(1).lower()
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)


def choice(question, keys, stream, out):
    """Asks until one of `keys` is pressed; "q" at the end of the input."""
    print(question, end=" ", flush=True, file=out)
    while True:
        key = read_key(stream)
        if key in keys:
            print(key, file=out)
            return key
        if not key:
            print(file=out)
            return "q"


def clipped(text):
    """The closing words as they read, within what fits a screen's reading: head and tail."""
    text = shown_block(text, len(text))[0]
    if len(text) <= SHOWN_CHARS:
        return text
    half = SHOWN_CHARS // 2
    return f"{text[:half]}\n\n[… {len(text) - SHOWN_CHARS} characters left out …]\n\n{text[-half:]}"


def age(at):
    try:
        days = (time.time() - datetime.fromisoformat(str(at).replace("Z", "+00:00")).timestamp()) / 86_400
    except ValueError:
        return ""
    return f"{int(days)}d ago" if days >= 1 else "today"


def show(turn, done, total, out):
    print("\033[2J\033[H" if out.isatty() else "", end="", file=out)
    place = Path(turn["path"]).parent.name
    print(f"{done + 1}/{total} · {turn['agent']}{' · work' if turn.get('profile') else ''} · {place} · {age(turn.get('at'))}\n", file=out)
    asked = (turn.get("requests") or ["(no request)"])[-1]
    print(f"You asked: {shown_block(asked, 300)[0]}\n", file=out)
    print(clipped(turn["said"]), file=out)
    print(file=out)


def label(cfg, stream=None, out=None, rng=None):
    """Asks you about turns until the sample is full or you quit, keeping each answer as it comes."""
    stream, out = stream or sys.stdin, out or sys.stdout
    path = labels_path(cfg)
    labels = read_labels(path)
    answered = [line for line in labels if line.get("wants") is not None]
    left = {True: FLAGGED - sum(1 for line in answered if line.get("flagged")),
            False: UNFLAGGED - sum(1 for line in answered if not line.get("flagged"))}
    done = len(answered)
    found = candidates(sources(), labels, rng or random.Random(), lambda is_flagged: left[is_flagged] > 0)
    pool = ThreadPoolExecutor(max_workers=2)
    ahead = deque()
    try:
        while left[True] > 0 or left[False] > 0:
            # The model's reading is on its way before you get there.
            while len(ahead) < 2:
                turn = next(found, None)
                if turn is None:
                    break
                ahead.append((turn, pool.submit(ask_model, turn, cfg)))
            if not ahead:
                print("The transcripts ran out before the sample filled.", file=out)
                break
            turn, reading = ahead.popleft()
            if left[turn["flagged"]] <= 0:
                reading.cancel()
                continue
            show(turn, done, FLAGGED + UNFLAGGED, out)
            wants = choice("Should the bar have called you for this? [y]es [n]o [s]kip [q]uit", "ynsq", stream, out)
            if wants == "q":
                print(f"{done} turns labelled so far. Run this again to carry on.", file=out)
                return
            line = {"at": int(time.time() * 1000), "agent": turn["agent"], "profile": turn.get("profile"), "path": turn["path"],
                    "turn": turn["id"], "flagged": turn["flagged"], "prompt": judge.VERSION}
            if wants == "s":
                worklog.append(path, {**line, "wants": None})
                continue
            did_ok = None
            did = reading.result().get("did")
            if did:
                print(f"\nThe model's did line: {shown_block(did, 300)[0]}", file=out)
                did_ok = {"y": True, "n": False}.get(choice("Is it accurate? [y]es [n]o [s]kip", "yns", stream, out))
            worklog.append(path, {**line, "wants": wants == "y", "didOk": did_ok})
            left[turn["flagged"]] -= 1
            done += 1
        else:
            print(f"{done} turns labelled, the sample is full. Run `agent-hub eval`.", file=out)
    finally:
        pool.shutdown(wait=False, cancel_futures=True)


def wilson(hits, total, z=1.96):
    """The 95% interval of a rate from `total` samples, which a small sample needs saying."""
    if not total:
        return 0.0, 1.0
    rate = hits / total
    denominator = 1 + z * z / total
    centre = (rate + z * z / (2 * total)) / denominator
    margin = z * math.sqrt(rate * (1 - rate) / total + z * z / (4 * total * total)) / denominator
    return max(0.0, centre - margin), min(1.0, centre + margin)


def rate_line(name, hits, total, target=None):
    if not total:
        return f"{name}: no turns to say"
    low, high = wilson(hits, total)
    goal = ""
    if target is not None:
        goal = f"  target {target:.0%}: {'met' if hits / total >= target else 'not met'}"
    return f"{name}: {hits}/{total} = {hits / total:.0%} (95% interval {low:.0%}-{high:.0%}){goal}"


def replay(line, cache):
    """A label's turn as it reads now, or None when its transcript moved on or went."""
    key = (line.get("agent"), line.get("path"))
    if key not in cache:
        cache[key] = {turn.get("id"): turn for turn in read_turns(*key)}
    turn = cache[key].get(line.get("turn"))
    return {**turn, "agent": line["agent"], "profile": line.get("profile"), "path": line["path"]} if turn else None


def summary(results, gone, words_only):
    """The eval's report, from `(label line, turn, outcome)` per turn still readable."""
    wanted = [r for r in results if r[0]["wants"]]
    quiet = [r for r in results if not r[0]["wants"]]

    def called(result):
        return result[2]["state"] == "blocked"

    true_pos, false_pos = sum(map(called, wanted)), sum(map(called, quiet))
    found = sum(r[2]["candidate"] for r in wanted)
    lines = [
        f"prompt {judge.VERSION} · {'the regex alone, no model' if words_only else 'regex and model'} · "
        f"{len(results)} turns" + (f", {gone} no longer readable" if gone else ""),
        "",
        f"{'':<18}{'called you':>12}{'stayed quiet':>14}",
        f"{'wanted you':<18}{true_pos:>12}{len(wanted) - true_pos:>14}",
        f"{'did not':<18}{false_pos:>12}{len(quiet) - false_pos:>14}",
        "",
        rate_line("recall", true_pos, len(wanted), TARGET_RECALL),
        rate_line("precision", true_pos, true_pos + false_pos, TARGET_PRECISION),
        rate_line("asks the regex reached", found, len(wanted)),
    ]
    rated = [r[0]["didOk"] for r in results if r[0].get("didOk") is not None]
    lines.append(rate_line("did lines accurate", sum(rated), len(rated)))
    editing = [r for r in results if r[1].get("unchecked") is not None]
    fired = [r for r in editing if r[1]["unchecked"]]
    healthy = [r for r in fired if not r[0]["wants"]]
    lines.append(f"an \"unverified\" marker would fire on {len(fired)} of {len(editing)} editing turns, "
                 f"{len(healthy)} of them turns you said didn't need you")
    misses = [r for r in wanted if not called(r)]
    alarms = [r for r in quiet if called(r)]
    for name, group in (("missed", misses), ("false alarm", alarms)):
        for line, _, _ in group:
            lines.append(f"{name}: {line.get('turn')} in {line.get('path')}")
    return "\n".join(lines)


def evaluate(cfg, words_only=False, out=None):
    """Replays the current gate over your labels and prints how it did: with the model's word,
    or `words_only` for the regex alone and no model calls."""
    out = out or sys.stdout
    labels = [line for line in read_labels(labels_path(cfg)) if line.get("wants") is not None]
    if not labels:
        print("No labels yet: run `agent-hub label` first.", file=out)
        return
    cache = {}
    turns = [(line, replay(line, cache)) for line in labels]
    readable = [(line, turn) for line, turn in turns if turn is not None]

    def judged(pair):
        line, turn = pair
        return line, turn, verdict(turn, {} if words_only else ask_model(turn, cfg))

    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        results = list(pool.map(judged, readable))
    print(summary(results, len(turns) - len(readable), words_only), file=out)
    errors = sorted(worklog.estimate_errors(log_path(cfg)))
    if errors:
        print(f"long-command estimates: {len(errors)}, off by a median of {errors[len(errors) // 2]:.0f} minutes", file=out)
