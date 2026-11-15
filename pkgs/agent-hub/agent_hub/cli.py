"""The `agent-hub` command: the daemon, Claude Code's hook, and the one-shot verbs."""

import argparse
import json
import os
import re
import socket
import sys
from pathlib import Path

from .common import hub_message, label_line, load_config, now_ms, socket_path

# What the hook sends of the closing words, which the hub reads for a turn that stopped to wait on its jobs.
SAID_MAX = 20_000
# The hook's input doesn't say where a prompt came from. Claude Code opens a peer's with a line of
# its own and this tag, so only the head counts: you may well quote the tag in a prompt.
PEER_PROMPT = re.compile(r"<cross-session-message\s+from=")
PEER_HEAD = 200


def peer_prompt(prompt):
    """Whether a UserPromptSubmit's prompt is another session's message, not the person's."""
    return bool(PEER_PROMPT.search(str(prompt or "")[:PEER_HEAD]))


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


def stop_tasks(event):
    """What a Stop event says is still in flight, as the hub takes it."""
    tasks = event.get("background_tasks")
    return [{"type": str(t.get("type") or ""), "description": label_line(t.get("description") or "")}
            for t in tasks if isinstance(t, dict)] if isinstance(tasks, list) else []


def cmd_hook(_args):
    """Claude Code's hook into the hub, fire-and-forget and silent: UserPromptSubmit starts a
    turn, Stop ends it with the closing words and the tasks still out, StopFailure ends it on
    an API error."""
    try:
        event = json.load(sys.stdin)
    except ValueError:
        return
    name = event.get("hook_event_name")
    session = hook_session(event)
    if not session or name not in ("UserPromptSubmit", "Stop", "StopFailure"):
        return
    who = {"session": session, "pid": hook_pid(), "cwd": event.get("cwd"), "tmux": os.environ.get("TMUX_PANE"),
           "transcript": event.get("transcript_path"),
           **({"hidden": True} if os.environ.get("AGENT_HUB_HIDDEN") == "1" else {})}
    if name == "UserPromptSubmit":
        hub_message({"op": "turn-start", **({"peer": True} if peer_prompt(event.get("prompt")) else {}), **who})
    elif name == "Stop":
        hub_message({"op": "turn-end", "said": str(event.get("last_assistant_message") or "")[-SAID_MAX:],
                     "tasks": stop_tasks(event), **who})
    else:
        reason = event.get("last_assistant_message") or event.get("error_details") or event.get("error") or "API error"
        hub_message({"op": "turn-end", "failure": label_line(reason), **who})


def cmd_focus_next(_args):
    hub_message({"op": "focus-next"})


def cmd_toggle(_args):
    hub_message({"op": "toggle"})


def demo_sessions():
    """Registry-shaped fake sessions, one in each state."""
    t = now_ms()
    entries = [
        ("demo-ask", "pi", "waiting", "etc hosts cleanup", {"project": "nixos", "waitingFor": "write: /etc/hosts"}),
        ("demo-fail", "cli", "idle", "nightly bot", {"project": "nixos", "turnState": "failed", "summary": "API error: overloaded"}),
        ("demo-done", "pi", "idle", "footer popup width", {"project": "pi-mono", "turnState": "done",
                                                          "said": "Fixed the footer popup width on narrow terminals."}),
        ("demo-busy", "cli", "busy", "devenv-tilt-68", {"project": "devenv-tilt"}),
        ("demo-idle", "pi", "idle", "dotfiles", {"project": "dotfiles"}),
    ]
    return [
        {"sessionId": sid, "pid": 0, "kind": "interactive", "entrypoint": entry, "status": status, "name": name,
         "cwd": str(Path.home() / "dev" / sid), "statusUpdatedAt": t - 60_000 * (i + 1), **extra}
        for i, (sid, entry, status, name, extra) in enumerate(entries)
    ]


def cmd_attach(_args):
    from .links import attach

    attach()


def cmd_demo(_args):
    sock = socket.socket(socket.AF_UNIX)
    sock.connect(str(socket_path()))
    sessions = demo_sessions()
    sock.sendall((json.dumps({"op": "demo", "sessions": sessions}) + "\n").encode())
    print("Demo sessions are on the bar until you press Ctrl-C.", flush=True)
    try:
        sock.recv(1)
    except KeyboardInterrupt:
        pass


def cmd_daemon(_args):
    # Imported here: the hook runs on every prompt.
    import asyncio

    from .hub import Hub

    asyncio.run(Hub(load_config()).run())


def main(argv=None):
    parser = argparse.ArgumentParser(prog="agent-hub", description="The hub for live coding-agent sessions")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("daemon", help="serve the hub socket").set_defaults(func=cmd_daemon)
    commands.add_parser("attach", help="bridge stdin and stdout to this host's hub, read-only, for a viewer over ssh").set_defaults(func=cmd_attach)
    commands.add_parser("demo", help="show fake sessions in every state on the bar").set_defaults(func=cmd_demo)
    commands.add_parser("hook", help="Claude Code's hook: UserPromptSubmit, Stop, StopFailure").set_defaults(func=cmd_hook)
    commands.add_parser("focus-next", help="focus the next session that wants you").set_defaults(func=cmd_focus_next)
    commands.add_parser("toggle", help="dismiss or bring back the focused session's finished turn").set_defaults(func=cmd_toggle)
    args = parser.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    sys.exit(main())
