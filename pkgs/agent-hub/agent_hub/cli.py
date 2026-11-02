"""The `agent-hub` command: the daemon, the Claude Code hook, and the one-shot verbs."""

import argparse
import json
import os
import socket
import sys
from datetime import datetime
from pathlib import Path

from . import worklog
from .claude import claude_label
from .common import (
    folded, hub_message, hub_request, hub_state, load_config, log_path, nearest, now_ms, resume_command, socket_path,
)


def status_row(rows, session_id=None, pid=None):
    """The row of one session, by registry id first and pid second.

    The id wins because a session knows its own; the pid is what a caller spawned
    into the session has, so it also finds the session of the nearest ancestor that
    is one. A Claude Code session gets a new id after /clear, so an id that matches
    nothing still falls back to the pid."""
    for row in rows:
        if session_id and row.get("id") == session_id:
            return row
    if pid is not None:
        return nearest(pid, {row.get("pid"): row for row in rows if row.get("pid")})
    return None


def cmd_status(args):
    """Prints this session's row as `state<TAB>reason<TAB>label` (`--json` for the row
    itself), and nothing at all when the hub is down or does not know the session:
    this feeds status lines, which must never fail or print an error of their own."""
    state = hub_state()
    row = status_row((state or {}).get("sessions") or [], args.session_id, args.pid)
    if row is None:
        return
    if args.json:
        print(json.dumps(row))
    else:
        print("\t".join(folded(row.get(key) or "") for key in ("state", "reason", "label")))


def cmd_recent(args):
    """Lists the sessions that ended, newest first: `label<TAB>resume command`."""
    state = hub_state()
    if state is None:
        sys.exit("agent-hub: the hub is not running")
    for item in state.get("recent") or []:
        print(json.dumps(item) if args.json else f"{item['label']}\t{item['resume']}")


def hook_session(event):
    """The registry's id for the hook's own Claude Code, whose event id goes stale after /clear."""
    try:
        entry = json.loads((Path(load_config()["registry"]).expanduser() / f"{int(os.environ['CLAUDE_PID'])}.json").read_text())
    except (KeyError, OSError, ValueError):
        entry = None
    return str((entry.get("sessionId") if isinstance(entry, dict) else None) or event.get("session_id") or "")


def hook_pid():
    try:
        return int(os.environ["CLAUDE_PID"])
    except (KeyError, ValueError):
        return None


def cmd_hook(_args):
    """Claude Code's hook into the hub. It prints nothing but UserPromptSubmit's note on
    the other sessions in the working tree, so Claude's own handling is unchanged:
    SessionStart names the profile, UserPromptSubmit starts a turn, Stop ends it,
    PermissionRequest labels the dialog, SessionEnd lets the session go."""
    try:
        event = json.load(sys.stdin)
    except ValueError:
        return
    name = event.get("hook_event_name")
    session = hook_session(event)
    if not session:
        return
    who = {"session": session, "pid": hook_pid(), "configDir": os.environ.get("CLAUDE_CONFIG_DIR"),
           "cwd": event.get("cwd")}
    transcript = event.get("transcript_path")
    if name == "SessionStart":
        hub_message({"op": "session-start", **who})
    elif name == "UserPromptSubmit":
        reply = hub_request({"op": "turn-start", "request": 1, "transcript": transcript,
                             "prompt": event.get("prompt"), **who})
        if reply and reply.get("peers"):
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit",
                                                     "additionalContext": reply["peers"]}}))
    elif name == "Stop":
        hub_message({"op": "turn-end", "transcript": transcript, **who})
    elif name == "PermissionRequest":
        hub_message({"op": "dialog", "session": session,
                     "text": claude_label(event.get("tool_name"), event.get("tool_input"), event.get("cwd"))})
    elif name == "SessionEnd":
        # The event's own id is the one ending; after /clear the registry already lists its successor.
        ended = {str(event.get("session_id") or "")} | ({session} if event.get("reason") != "clear" else set())
        for sid in ended - {""}:
            hub_message({"op": "session-end", "session": sid})


def cmd_log(args):
    """Prints the work log since `--since`, grouped by session: its label and resume
    command, then one line per turn."""
    since = worklog.since_ms(args.since)
    groups = worklog.by_session(worklog.read(log_path(load_config()), since))
    for group in groups:
        if args.json:
            for line in group:
                print(json.dumps(line))
            continue
        print_group(group)


def cmd_find(args):
    """Prints the sessions whose log mentions every word, latest last."""
    groups = [g for g in worklog.by_session(worklog.read(log_path(load_config()))) if worklog.matches(g, args.words)]
    for group in groups:
        print_group(group)


def print_group(group):
    last = group[-1]
    resume = resume_command(last.get("agent"), last.get("session") or "", last.get("cwd"), last.get("configDir"))
    print(f"{last.get('label') or '(unnamed)'}\t{resume}")
    for line in group:
        stamp = datetime.fromtimestamp((line.get("at") or 0) / 1000).strftime("%a %H:%M")
        text = line.get("did") or ""
        if line.get("ask"):
            text = f"{text} [asks: {line['ask']}]".strip()
        print(f"  {stamp}  {line.get('state') or 'done':<11} {folded(text)}")


def cmd_focus_next(_args):
    hub_message({"op": "focus-next"})


def cmd_toggle(_args):
    hub_message({"op": "toggle"})


def demo_sessions():
    """Registry-shaped fake sessions, one or more per state."""
    t = now_ms()
    entries = [
        ("demo-bash", "cli", "waiting", "nixos-d0", {"waitingFor": "Bash: cd ~/dev/app && git fetch origin && git rebase origin/main && rm -rf build/"}),
        ("demo-path", "pi", "waiting", "etc hosts cleanup", {"waitingFor": "write: /etc/hosts"}),
        ("demo-ask", "pi", "idle", "fixture cleanup", {"turnState": "blocked", "ask": "keep the old fixture, or regenerate it?"}),
        ("demo-fail", "pi", "idle", "nightly bot", {"turnState": "failed", "summary": "The update bot still fails on the darwin eval."}),
        ("demo-done", "pi", "idle", "footer popup width", {"turnState": "done", "summary": "Fixed the footer popup width on narrow terminals."}),
        ("demo-busy1", "cli", "busy", "devenv-tilt-68", {}),
        ("demo-busy2", "pi", "busy", "flaky ci retries", {"doing": "rerunning the retry test"}),
        ("demo-idle1", "cli", "idle", "dotfiles-2a", {}),
        ("demo-idle2", "pi", "idle", "homelab grafana alerts", {}),
    ]
    return [
        {"sessionId": sid, "pid": 0, "kind": "interactive", "entrypoint": entry, "status": status, "name": name,
         "cwd": str(Path.home() / "dev" / sid), "statusUpdatedAt": t - 60_000 * (i + 1), **extra}
        for i, (sid, entry, status, name, extra) in enumerate(entries)
    ]


def cmd_demo(_args):
    sock = socket.socket(socket.AF_UNIX)
    sock.connect(str(socket_path()))
    sock.sendall((json.dumps({"op": "demo", "sessions": demo_sessions()}) + "\n").encode())
    print("Demo sessions are on the bar until you press Ctrl-C.", flush=True)
    try:
        sock.recv(1)
    except KeyboardInterrupt:
        pass


def cmd_daemon(_args):
    # Imported here: the hook and `status` run on every prompt and status-line refresh.
    import asyncio

    from .hub import Hub

    asyncio.run(Hub(load_config()).run())


def main(argv=None):
    parser = argparse.ArgumentParser(prog="agent-hub", description="The hub for live coding-agent sessions")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("daemon", help="serve the hub socket").set_defaults(func=cmd_daemon)
    commands.add_parser("demo", help="show fake sessions in every state on the bar").set_defaults(func=cmd_demo)
    commands.add_parser("hook", help="Claude Code's hook: SessionStart, UserPromptSubmit, Stop, PermissionRequest, SessionEnd").set_defaults(func=cmd_hook)
    log = commands.add_parser("log", help="print what every session did, turn by turn")
    log.add_argument("--since", default="1d", help="1d, 3h, 2w, today, yesterday or a date (default 1d)")
    log.add_argument("--json", action="store_true", help="print the log's own JSON lines")
    log.set_defaults(func=cmd_log)
    find = commands.add_parser("find", help="find sessions by what they were called or did, with how to resume them")
    find.add_argument("words", nargs="+")
    find.set_defaults(func=cmd_find)
    recent = commands.add_parser("recent", help="list the sessions that ended, with the command that resumes each")
    recent.add_argument("--json", action="store_true", help="print each session as a JSON line")
    recent.set_defaults(func=cmd_recent)
    commands.add_parser("focus-next", help="focus the next session that wants you").set_defaults(func=cmd_focus_next)
    status = commands.add_parser("status", help="print one session's state, as its own agent TUI shows it")
    status.add_argument("--session-id", help="the session's registry id")
    status.add_argument("--pid", type=int, help="the agent's pid, or a pid under it")
    status.add_argument("--json", action="store_true", help="print the hub's row instead of state, reason and label")
    status.set_defaults(func=cmd_status)
    commands.add_parser("toggle", help="dismiss or bring back the focused session's finished turn").set_defaults(func=cmd_toggle)
    args = parser.parse_args(argv)
    if args.command == "status" and args.session_id is None and args.pid is None:
        parser.error("status needs --session-id or --pid")
    args.func(args)


if __name__ == "__main__":
    sys.exit(main())
