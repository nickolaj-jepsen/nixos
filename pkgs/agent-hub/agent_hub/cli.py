"""The `agent-hub` command: the daemon, the Claude Code hook, and the one-shot verbs."""

import argparse
import json
import os
import re
import socket
import sys
from datetime import datetime
from pathlib import Path

from . import worklog
from .claude import SAID_MAX, claude_label, permission_ask
from .common import (
    folded, hub_message, hub_request, hub_state, label_line, load_config, log_path, nearest, now_ms, resume_command, socket_path,
)

# The hook's input doesn't say where a prompt came from. Claude Code opens a peer's with a line of
# its own and this tag, so only the head counts: you may well quote the tag in a prompt.
PEER_PROMPT = re.compile(r"<cross-session-message\s+from=")
PEER_HEAD = 200


def peer_prompt(prompt):
    """Whether a UserPromptSubmit's prompt is another session's message, not the person's."""
    return bool(PEER_PROMPT.search(str(prompt or "")[:PEER_HEAD]))


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
    this feeds status lines, which must never fail or print an error of their own.
    Naming no session, prints every row and how many are hidden (`--json` for the state)."""
    state = hub_state()
    if args.session_id is None and args.pid is None:
        print_state(state, args.json)
        return
    row = status_row((state or {}).get("sessions") or [], args.session_id, args.pid)
    if row is None:
        return
    if args.json:
        print(json.dumps(row))
    else:
        print("\t".join(folded(row.get(key) or "") for key in ("state", "reason", "label")))


def print_state(state, as_json):
    if state is None:
        return
    if as_json:
        print(json.dumps(state))
        return
    for row in state.get("sessions") or []:
        print("\t".join(folded(str(row.get(key) or "")) for key in ("state", "name", "cwd", "reason")))
    if state.get("hidden"):
        print(f"hidden\t{state['hidden']}")


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


def stop_tasks(event):
    """What a Stop event says is still in flight, as the hub takes it."""
    tasks = event.get("background_tasks")
    return [{"type": str(t.get("type") or ""), "description": label_line(t.get("description") or "")}
            for t in tasks if isinstance(t, dict)] if isinstance(tasks, list) else []


def cmd_hook(_args):
    """Claude Code's hook into the hub. It prints only UserPromptSubmit's note on the other
    sessions in the working tree and the answer to a prompt given at the bar:
    SessionStart names the profile, UserPromptSubmit starts a turn, Stop ends it with
    the closing words and the tasks still out, StopFailure ends it on an API error,
    PermissionRequest shows the prompt and waits on the hub, which Claude's own dialog
    races, SessionEnd lets the session go. `AGENT_HUB=off` turns it all off for a session,
    as if there were no hub."""
    if os.environ.get("AGENT_HUB") == "off":
        return
    try:
        event = json.load(sys.stdin)
    except ValueError:
        return
    name = event.get("hook_event_name")
    session = hook_session(event)
    if not session:
        return
    who = {"session": session, "pid": hook_pid(), "configDir": os.environ.get("CLAUDE_CONFIG_DIR"),
           "cwd": event.get("cwd"), "tmux": os.environ.get("TMUX_PANE"),
           **({"hidden": True} if os.environ.get("AGENT_HUB_HIDDEN") == "1" else {})}
    transcript = event.get("transcript_path")
    if name == "SessionStart":
        hub_message({"op": "session-start", **who})
    elif name == "UserPromptSubmit":
        origin = {"fromPerson": False, "peer": True} if peer_prompt(event.get("prompt")) else {"prompt": event.get("prompt")}
        reply = hub_request({"op": "turn-start", "request": 1, "transcript": transcript, **origin, **who})
        if reply and reply.get("peers"):
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit",
                                                     "additionalContext": reply["peers"]}}))
    elif name == "Stop":
        hub_message({"op": "turn-end", "transcript": transcript, "said": str(event.get("last_assistant_message") or "")[-SAID_MAX:],
                     "tasks": stop_tasks(event), **who})
    elif name == "StopFailure":
        reason = event.get("last_assistant_message") or event.get("error_details") or event.get("error") or "API error"
        hub_message({"op": "turn-end", "transcript": transcript, "failure": label_line(reason), **who})
    elif name == "PermissionRequest":
        tool, args, cwd = event.get("tool_name"), event.get("tool_input"), event.get("cwd")
        reply = hub_request({"op": "permission", "request": 1, "text": claude_label(tool, args, cwd),
                             "ask": permission_ask(tool, args, cwd), **who}, timeout=None)
        decision = (reply or {}).get("decision")
        if decision in ("allow", "deny"):
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {
                "behavior": decision, **({"message": "Denied from the agent hub."} if decision == "deny" else {})}}}))
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
        if "next" in line:
            continue
        stamp = datetime.fromtimestamp((line.get("at") or 0) / 1000).strftime("%a %H:%M")
        text = line.get("did") or ""
        if line.get("ask"):
            text = f"{text} [asks: {line['ask']}]".strip()
        answered = {"allow": "allowed ", "deny": "denied "}.get(line.get("answered"), "")
        flag = "wrong " if line.get("wrong") else "unopened " if line.get("unopened") else "peer " if line.get("peer") else answered
        word = flag + (line.get("state") or "done")
        print(f"  {stamp}  {word:<11} {folded(text)}")


def cmd_focus_next(_args):
    hub_message({"op": "focus-next"})


def cmd_toggle(_args):
    hub_message({"op": "toggle"})


def demo_sessions():
    """Registry-shaped fake sessions, one or more per state."""
    t = now_ms()
    entries = [
        ("demo-path", "pi", "waiting", "etc hosts cleanup", {"waitingFor": "write: /etc/hosts", "prompt": "Remove the old staging entries."}),
        ("demo-edit", "cli", "waiting", "dms-gamma", {
            "waitingFor": "Edit: modules/desktop/dms/gamma.nix", "prompt": "The screen is too warm at night, lower it a bit.", "branch": "main",
            "permission": {"id": 0, "tool": "Edit", "about": "modules/desktop/dms/gamma.nix", "kind": "diff", "complete": True,
                           "body": "- nightTemperature = 3400;\n+ nightTemperature = 4000;"}}),
        ("demo-bash", "cli", "waiting", "nixos-d0", {
            "waitingFor": "Bash: cd ~/dev/app && git fetch origin && git rebase origin/main && rm -rf build/",
            "prompt": "Rebase this on main and clean up the old build output.", "branch": "main", "changed": 3, "peers": ["dotfiles-2a"],
            "history": [{"at": t - 720_000, "state": "done", "did": "Fixed the failing auth tests"}],
            "permission": {"id": 0, "tool": "Bash", "about": "Rebase onto main and remove the build folder", "kind": "command", "complete": True,
                           "body": "cd ~/dev/app && git fetch origin\ngit rebase origin/main && rm -rf build/"}}),
        ("demo-ask", "pi", "idle", "fixture cleanup", {
            "turnState": "blocked", "ask": "keep the old fixture, or regenerate it?", "reply": "Regenerate it", "prompt": "Clean up the test fixtures.",
            "said": "The old fixture still passes, but it pins a format nothing else writes any more.\n\nKeep the old fixture, or regenerate it?"}),
        ("demo-fail", "pi", "idle", "nightly bot", {"turnState": "failed", "summary": "The update bot still fails on the darwin eval."}),
        ("demo-done", "pi", "idle", "footer popup width", {"turnState": "done", "summary": "Fixed the footer popup width on narrow terminals."}),
        ("demo-busy1", "cli", "busy", "devenv-tilt-68", {}),
        ("demo-busy2", "pi", "busy", "flaky ci retries", {
            "doing": "Rerunning the retry test under load.", "branch": "retries", "activity": t - 30_000,
            "now": "just test retries", "nowAt": t - 720_000, "counts": {"edits": 4, "commands": 7, "failed": 1},
            "trail": [{"at": t - 1_500_000, "text": "Reading the retry code."}, {"at": t - 1_200_000, "text": "Wrote a test that fails the same way."},
                      {"at": t - 720_000, "text": "Rerunning the retry test under load."}]}),
        ("demo-idle1", "cli", "idle", "dotfiles-2a", {}),
        ("demo-idle2", "pi", "idle", "homelab grafana alerts", {}),
    ]
    return [
        {"sessionId": sid, "pid": 0, "kind": "interactive", "entrypoint": entry, "status": status, "name": name,
         "cwd": str(Path.home() / "dev" / sid), "statusUpdatedAt": t - 60_000 * (i + 1), **extra}
        for i, (sid, entry, status, name, extra) in enumerate(entries)
    ]


def cmd_attach(args):
    from .links import attach

    attach(args.control)


def cmd_demo(_args):
    sock = socket.socket(socket.AF_UNIX)
    sock.connect(str(socket_path()))
    sock.sendall((json.dumps({"op": "demo", "sessions": demo_sessions()}) + "\n").encode())
    print("Demo sessions are on the bar until you press Ctrl-C.", flush=True)
    try:
        sock.recv(1)
    except KeyboardInterrupt:
        pass


def cmd_label(_args):
    from .bench import label

    try:
        label(load_config())
    except KeyboardInterrupt:
        print()


def cmd_eval(args):
    from .bench import evaluate

    evaluate(load_config(), args.words_only)


def cmd_daemon(_args):
    # Imported here: the hook and `status` run on every prompt and status-line refresh.
    import asyncio

    from .hub import Hub

    asyncio.run(Hub(load_config()).run())


def main(argv=None):
    parser = argparse.ArgumentParser(prog="agent-hub", description="The hub for live coding-agent sessions")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("daemon", help="serve the hub socket").set_defaults(func=cmd_daemon)
    attach = commands.add_parser("attach", help="bridge stdin and stdout to this host's hub, for a viewer over ssh")
    attach.add_argument("--control", action="store_true", help="also let the viewer dismiss a finished turn")
    attach.set_defaults(func=cmd_attach)
    commands.add_parser("demo", help="show fake sessions in every state on the bar").set_defaults(func=cmd_demo)
    commands.add_parser("hook", help="Claude Code's hook: SessionStart, UserPromptSubmit, Stop, StopFailure, PermissionRequest, SessionEnd").set_defaults(func=cmd_hook)
    log = commands.add_parser("log", help="print what every session did, turn by turn")
    log.add_argument("--since", default="1d", help="1d, 3h, 2w, today, yesterday or a date (default 1d)")
    log.add_argument("--json", action="store_true", help="print the log's own JSON lines")
    log.set_defaults(func=cmd_log)
    commands.add_parser("label", help="say whether past turns should have called you, for `eval`").set_defaults(func=cmd_label)
    evaluate = commands.add_parser("eval", help="replay the gate over your labels and print how it did")
    evaluate.add_argument("--words-only", action="store_true", help="the regex alone, with no model calls")
    evaluate.set_defaults(func=cmd_eval)
    find = commands.add_parser("find", help="find sessions by what they were called or did, with how to resume them")
    find.add_argument("words", nargs="+")
    find.set_defaults(func=cmd_find)
    recent = commands.add_parser("recent", help="list the sessions that ended, with the command that resumes each")
    recent.add_argument("--json", action="store_true", help="print each session as a JSON line")
    recent.set_defaults(func=cmd_recent)
    commands.add_parser("focus-next", help="focus the next session that wants you").set_defaults(func=cmd_focus_next)
    status = commands.add_parser("status", help="print one session's state, as its own agent TUI shows it, or every session's")
    status.add_argument("--session-id", help="the session's registry id")
    status.add_argument("--pid", type=int, help="the agent's pid, or a pid under it")
    status.add_argument("--json", action="store_true", help="print the hub's row instead of state, reason and label")
    status.set_defaults(func=cmd_status)
    commands.add_parser("toggle", help="dismiss or bring back the focused session's finished turn").set_defaults(func=cmd_toggle)
    args = parser.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    sys.exit(main())
