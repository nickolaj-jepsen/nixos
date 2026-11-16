"""Protocol tests: a real daemon on a temp runtime dir, a temp session registry and
a scripted niri, driven over its socket."""

import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from pathlib import Path

from agent_hub import links

PACKAGE = Path(__file__).resolve().parent.parent
TIMEOUT = 5

FAKE_NIRI = """#!{python}
import json, os, sys
args = sys.argv[1:]
if "event-stream" in args:
    with open({sockets!r}, "a") as log:
        log.write(str(os.environ.get("NIRI_SOCKET")) + "\\n")
    with open({fifo!r}) as events:
        for line in events:
            print(line, end="", flush=True)
elif "focus-window" in args:
    with open({log!r}, "a") as log:
        log.write(args[-1] + "\\n")
elif "spawn" in args:
    with open({log!r} + ".spawn", "a") as log:
        log.write(json.dumps(args[args.index("--") + 1:]) + "\\n")
"""

class Client:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(str(path))
        self.buffer = b""

    def send(self, **message):
        self.sock.sendall((json.dumps(message) + "\n").encode())

    def recv(self, timeout=TIMEOUT):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError
            self.sock.settimeout(left)
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("hub closed the connection")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def wait(self, predicate, timeout=TIMEOUT):
        """The first message `predicate` accepts; raises TimeoutError."""
        deadline = time.monotonic() + timeout
        while True:
            message = self.recv(max(deadline - time.monotonic(), 0.001))
            if predicate(message):
                return message

    def close(self):
        self.sock.close()


class Hub:
    """A daemon on a desktop by default; `headless` drops niri, polls the
    registry and leaves it no runtime dir, as on a server or a Mac."""

    def __init__(self, headless=False, extra=None):
        self.tmp = Path(tempfile.mkdtemp(prefix="agent-hub-test-"))
        self.registry = self.tmp / "sessions"
        self.registry.mkdir()
        fifo = self.tmp / "niri.fifo"
        os.mkfifo(fifo)
        # Read-write so neither side blocks on open, and the stream outlives a reader.
        self.niri_events = os.open(fifo, os.O_RDWR)
        self.focus_log = self.tmp / "focus.log"
        self.socket_log = self.tmp / "niri-socket.log"
        niri = self.tmp / "niri"
        niri.write_text(
            FAKE_NIRI.format(python=sys.executable, fifo=str(fifo), log=str(self.focus_log), sockets=str(self.socket_log))
        )
        niri.chmod(0o755)
        config = self.tmp / "config.json"
        desktop = {"niri": str(niri), "terminal": ["ghostty", "--working-directory={cwd}", "-e"]}
        config.write_text(json.dumps({
            "registry": str(self.registry),
            "git": shutil.which("git"),
            **({"poll": True} if headless else desktop),
            **(extra or {}),
        }))
        runtime = self.tmp / "run"
        runtime.mkdir(mode=0o700)
        self.env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), XDG_STATE_HOME=str(self.tmp / "state"),
                        AGENT_HUB_CONFIG=str(config))
        if headless:
            del self.env["XDG_RUNTIME_DIR"]
            self.socket = self.tmp / "state" / "agent-hub" / "hub.sock"
        else:
            self.socket = runtime / "agent-hub" / "hub.sock"
        # Run inside a Claude session, the hooks would otherwise name that session's pid.
        for name in ("CLAUDE_CONFIG_DIR", "CLAUDE_PID"):
            self.env.pop(name, None)
        # The compositor's socket is discovered, not inherited, so keep the runner's out of it.
        self.env.pop("NIRI_SOCKET", None)
        self.processes = []
        self.clients = []
        self.start()

    def start(self):
        # Its own process group, so a restart reaps the fake niri with it: an orphan
        # would keep reading the event fifo behind the next daemon's back.
        self.daemon = subprocess.Popen([sys.executable, "-m", "agent_hub", "daemon"], env=self.env, cwd=PACKAGE, start_new_session=True)
        deadline = time.monotonic() + TIMEOUT
        while not self.socket.exists():
            if time.monotonic() > deadline or self.daemon.poll() is not None:
                raise RuntimeError("hub did not start")
            time.sleep(0.02)

    def kill(self):
        try:
            os.killpg(self.daemon.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.daemon.wait()

    def restart(self):
        self.kill()
        self.socket.unlink()
        self.start()

    def connect(self):
        client = Client(self.socket)
        self.clients.append(client)
        return client

    def subscribe(self):
        client = self.connect()
        client.send(op="subscribe")
        client.wait(lambda m: m["type"] == "state")
        return client

    def command(self, *args, stdin="", **env):
        return subprocess.run([sys.executable, "-m", "agent_hub", *args], env=dict(self.env, **env), cwd=PACKAGE, input=stdin, text=True,
                              check=True, capture_output=True, timeout=TIMEOUT)

    def write_transcript(self, name, entries):
        path = self.tmp / f"{name}.jsonl"
        path.write_text("".join(json.dumps(e) + "\n" for e in entries))
        return path

    def process(self, **env):
        proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(600)"], env=dict(os.environ, **env))
        self.processes.append(proc)
        return proc

    def write_session(self, pid, session_id, status="busy", kind="interactive", since=None, **fields):
        entry = {"pid": pid, "sessionId": session_id, "cwd": "/repo", "kind": kind, "entrypoint": "cli",
                 "name": "demo", "status": status, "statusUpdatedAt": since or int(time.time() * 1000), **fields}
        tmp = self.registry / f".{pid}.json.tmp"
        tmp.write_text(json.dumps(entry))
        tmp.rename(self.registry / f"{pid}.json")

    def niri(self, event):
        os.write(self.niri_events, (json.dumps(event) + "\n").encode())

    def focused(self):
        """The windows focus requests went to, in order."""
        return self.focus_log.read_text().split() if self.focus_log.exists() else []

    def stop(self):
        for client in self.clients:
            client.close()
        for proc in self.processes:
            proc.kill()
            proc.wait()
        self.kill()
        os.close(self.niri_events)


def eventually(predicate):
    deadline = time.monotonic() + TIMEOUT
    while not predicate():
        if time.monotonic() > deadline:
            raise TimeoutError
        time.sleep(0.02)


def session(state, session_id):
    return next((s for s in state["sessions"] if s["id"] == session_id), None)


def has_session(session_id, predicate=lambda s: True):
    return lambda m: m["type"] == "state" and (s := session(m, session_id)) is not None and predicate(s)


def lacks_session(session_id):
    return lambda m: m["type"] == "state" and session(m, session_id) is None


class HubTest(unittest.TestCase):
    def setUp(self):
        self.hub = Hub()
        self.addCleanup(self.hub.stop)
        self.sid = str(uuid.uuid4())


def prompt(text):
    return {"type": "user", "message": {"role": "user", "content": text}}


def said(text):
    return {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}


class SessionTest(HubTest):
    def test_a_headless_run_never_shows_though_it_registers_as_interactive(self):
        bar = self.hub.subscribe()
        headless, proc = str(uuid.uuid4()), self.hub.process()
        self.hub.write_session(self.hub.process().pid, headless, entrypoint="sdk-cli")
        self.hub.write_session(proc.pid, self.sid)
        state = bar.wait(has_session(self.sid))
        self.assertNotIn(headless, [row["id"] for row in state["sessions"]])

    def test_interactive_session_appears_and_drops_when_its_process_exits(self):
        bar = self.hub.subscribe()
        proc = self.hub.process()
        self.hub.write_session(proc.pid, self.sid, status="busy")
        bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))
        proc.kill()
        proc.wait()
        bar.wait(lacks_session(self.sid))

    def test_headless_sessions_are_not_shown(self):
        bar = self.hub.subscribe()
        headless, shown = self.hub.process(), self.hub.process()
        self.hub.write_session(headless.pid, "headless", kind="headless")
        self.hub.write_session(shown.pid, self.sid)
        state = bar.wait(has_session(self.sid))
        self.assertIsNone(session(state, "headless"))

    def test_parked_session_shows_its_bg_jobs_state_under_the_fronts_window(self):
        front, job = self.hub.process(), self.hub.process()
        self.hub.niri({"WindowsChanged": {"windows": [{"id": 7, "pid": front.pid, "is_focused": False}]}})
        bar = self.hub.subscribe()
        self.hub.write_session(job.pid, self.sid, status="busy", kind="bg", jobId="job1", name="live")
        self.hub.write_session(front.pid, "front", status="idle", parkedJobId="job1")
        state = bar.wait(has_session(self.sid, lambda s: s["state"] == "working" and s["window"] == 7))
        self.assertEqual(session(state, self.sid)["name"], "live")
        self.assertIsNone(session(state, "front"))
        job.kill()
        job.wait()
        bar.wait(has_session("front", lambda s: s["state"] == "idle"))

    def test_unparked_bg_jobs_are_not_shown(self):
        bar = self.hub.subscribe()
        job, shown = self.hub.process(), self.hub.process()
        self.hub.write_session(job.pid, "job", kind="bg", jobId="job1")
        self.hub.write_session(shown.pid, self.sid)
        state = bar.wait(has_session(self.sid))
        self.assertIsNone(session(state, "job"))

    def test_entry_of_a_dead_process_is_ignored(self):
        bar = self.hub.subscribe()
        proc = self.hub.process()
        proc.kill()
        proc.wait()
        self.hub.write_session(proc.pid, "dead")
        live = self.hub.process()
        self.hub.write_session(live.pid, self.sid)
        state = bar.wait(has_session(self.sid))
        self.assertIsNone(session(state, "dead"))

    def test_a_row_is_named_for_the_repository_from_any_worktree(self):
        repo = git_repo(self.hub.tmp / "myrepo")
        subprocess.run(["git", "-C", str(repo), "worktree", "add", "-q", str(self.hub.tmp / "wt"), "-b", "side"], check=True)
        bar = self.hub.subscribe()
        for cwd, sid in ((repo, self.sid), (self.hub.tmp / "wt", "other"), (self.hub.tmp / "loose", "loose")):
            cwd.mkdir(exist_ok=True)
            self.hub.write_session(self.hub.process().pid, sid, cwd=str(cwd))
        state = bar.wait(lambda m: m["type"] == "state" and all((session(m, s) or {}).get("project") for s in (self.sid, "other", "loose")))
        self.assertEqual([session(state, s)["project"] for s in (self.sid, "other", "loose")], ["myrepo", "myrepo", "loose"])
        self.assertNotIn("branch", session(state, self.sid))

    def test_a_person_names_it_with_rename_else_claudes_title_else_the_registry_else_the_folder(self):
        bar = self.hub.subscribe()
        proc = self.hub.process()
        transcript = self.hub.write_transcript(self.sid, [prompt("go"), {"type": "ai-title", "aiTitle": "Fix the footer"}])
        self.hub.write_session(proc.pid, self.sid, name="repo-12")
        bar.wait(has_session(self.sid, lambda s: s["name"] == "repo-12"))
        event = {"hook_event_name": "UserPromptSubmit", "session_id": self.sid, "prompt": "go", "transcript_path": str(transcript)}
        self.hub.command("hook", stdin=json.dumps(event))
        bar.wait(has_session(self.sid, lambda s: s["name"] == "Fix the footer"))
        self.hub.write_session(proc.pid, self.sid, name="mine", nameSource="user")
        bar.wait(has_session(self.sid, lambda s: s["name"] == "mine"))

    def test_a_cwdless_unnamed_entry_falls_back_to_the_folder(self):
        bar = self.hub.subscribe()
        self.hub.write_session(self.hub.process().pid, self.sid, name="", cwd="/home/x/folder")
        bar.wait(has_session(self.sid, lambda s: s["name"] == "folder"))


class HeadlessTest(unittest.TestCase):
    """A hub with no compositor and no runtime dir: the one on a server or a Mac."""

    def setUp(self):
        self.hub = Hub(headless=True)
        self.addCleanup(self.hub.stop)

    def test_polled_session_appears_without_a_window_and_drops_when_its_process_exits(self):
        bar = self.hub.subscribe()
        proc = self.hub.process()
        self.hub.write_session(proc.pid, "s1", status="busy")
        state = bar.wait(has_session("s1", lambda s: s["state"] == "working"))
        self.assertIsNone(session(state, "s1")["window"])
        proc.kill()
        proc.wait()
        bar.wait(lacks_session("s1"))


class TurnTest(HubTest):
    """How a pi turn ends, by its registry entry alone, and what looking at it does."""

    def setUp(self):
        super().setUp()
        self.proc = self.hub.process()
        self.window = 7
        self.hub.niri({"WindowsChanged": {"windows": [
            {"id": self.window, "pid": self.proc.pid, "is_focused": False},
            {"id": 8, "pid": 1, "is_focused": True},
        ]}})
        self.bar = self.hub.subscribe()
        self.at = int(time.time() * 1000)
        self.canaries = 0
        self.pi(status="idle")
        self.bar.wait(has_session(self.sid, lambda s: s["window"] == self.window))
        self.pi(status="busy")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))

    def pi(self, status, **fields):
        """pi's registry entry, as claude-peers.ts writes it."""
        self.at += 10
        self.hub.write_session(self.proc.pid, self.sid, status=status, entrypoint="pi", since=self.at, **fields)

    def busy(self, **fields):
        self.pi(status="busy", **fields)
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))

    def finish(self):
        self.pi(status="idle")
        return session(self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done")), self.sid)

    def fail(self, text="API error: overloaded"):
        self.pi(status="idle", hubFailed=text)
        return session(self.bar.wait(has_session(self.sid, lambda s: s["state"] == "failed")), self.sid)

    def focused_row(self, window):
        """This session's row, read off a canary write that makes the hub publish."""
        self.hub.niri({"WindowFocusChanged": {"id": window}})
        self.canaries += 1
        canary = self.hub.process()
        self.hub.write_session(canary.pid, "canary", status="busy", name=f"canary {self.canaries}")
        return session(self.bar.wait(has_session("canary")), self.sid)

    def test_a_pi_turn_that_goes_idle_is_done(self):
        self.finish()

    def test_a_turn_that_failed_says_why(self):
        row = self.fail()
        self.assertEqual(row["reason"], "API error: overloaded")

    def test_a_turn_woken_by_a_peer_is_not_yours_and_leaves_your_ending(self):
        self.finish()
        self.pi(status="busy", hubPeer=True)
        row = session(self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done")), self.sid)
        self.pi(status="idle")
        self.assertEqual(self.focused_row(8)["since"], row["since"])

    def test_a_peers_turn_that_failed_reaches_the_row(self):
        self.finish()
        self.pi(status="busy", hubPeer=True)
        self.focused_row(8)
        self.pi(status="idle", hubFailed="overloaded")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "failed"))

    def test_a_finished_turn_whose_window_has_focus_is_read_and_the_next_one_announces(self):
        self.hub.niri({"WindowFocusChanged": {"id": self.window}})
        self.pi(status="idle")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))
        self.pi(status="busy")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))

    def test_a_finished_turn_under_another_window_stays_until_it_is_read(self):
        self.finish()
        self.hub.niri({"WindowFocusChanged": {"id": 8}})
        self.hub.niri({"WindowFocusChanged": {"id": self.window}})
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))

    def test_dismissed_turn_is_idle_until_the_next_one_finishes(self):
        self.finish()
        self.bar.send(op="dismiss", session=self.sid)
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))
        self.busy()
        self.finish()

    def test_a_failed_turn_still_wants_you_when_its_window_is_focused(self):
        self.fail()
        self.assertEqual(self.focused_row(self.window)["state"], "failed")

    def test_toggle_dismisses_and_brings_back_the_focused_sessions_turn(self):
        self.fail()
        self.focused_row(self.window)
        self.bar.send(op="toggle")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))
        self.bar.send(op="toggle")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "failed"))

    def test_undo_brings_back_the_last_dismissal_without_a_pulse(self):
        self.fail()
        self.bar.send(op="dismiss", session=self.sid)
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))
        self.bar.send(op="undo")
        row = session(self.bar.wait(has_session(self.sid, lambda s: s["state"] == "failed")), self.sid)
        self.assertFalse(row["pulse"])

    def test_undo_drops_a_dismissal_once_the_session_started_a_new_turn(self):
        self.finish()
        self.bar.send(op="dismiss", session=self.sid)
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))
        self.busy()
        self.finish()
        self.hub.niri({"WindowFocusChanged": {"id": self.window}})
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))
        self.bar.send(op="undo")
        self.bar.send(op="subscribe")
        self.assertEqual(session(self.bar.wait(lambda m: m["type"] == "state"), self.sid)["state"], "idle")

    def test_focus_goes_to_the_sessions_window(self):
        self.bar.send(op="focus", session=self.sid)
        eventually(lambda: self.hub.focused() == [str(self.window)])

    def test_focus_next_cycles_through_what_wants_you(self):
        self.fail()
        self.bar.send(op="focus-next")
        eventually(lambda: self.hub.focused() == [str(self.window)])

    def test_a_waiting_pi_is_asking_with_its_own_reason(self):
        self.pi(status="waiting", waitingFor="write: /etc/hosts")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "asking" and s["waitingFor"] == "write: /etc/hosts"))

    def test_hidden_pi_is_off_the_bar_and_counted(self):
        self.pi(status="busy", hubHidden=True)
        state = self.bar.wait(lacks_session(self.sid))
        self.assertEqual(state["hidden"], 1)


class ClaudeTurnTest(HubTest):
    def setUp(self):
        super().setUp()
        self.proc = self.hub.process()
        self.bar = self.hub.subscribe()
        self.hub.write_session(self.proc.pid, self.sid, status="busy")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))
        self.hub.write_session(self.proc.pid, self.sid, status="idle")
        # A session whose writes make the hub publish, for reading its own row when it does not.
        self.canary = self.hub.process()
        self.canaries = 0

    def settled(self):
        """This session's row, read off a canary write the hub may well ignore."""
        self.canaries += 1
        self.hub.write_session(self.canary.pid, "canary", status="busy", name=f"canary {self.canaries}")
        # A rescan reads every entry, so this message also carries whatever changed in `sid`'s.
        return session(self.bar.wait(has_session("canary")), self.sid)

    def hook(self, name, session_id=None, payload=None, entries=None, **env):
        event = {"hook_event_name": name, "session_id": session_id or self.sid, **(payload or {})}
        if entries is not None:
            event["transcript_path"] = str(self.hub.write_transcript(self.sid, entries))
        return self.hub.command("hook", stdin=json.dumps(event), **env)

    def stop(self, said_text="Done.", **kw):
        return self.hook("Stop", payload={"last_assistant_message": said_text, **kw.pop("payload", {}), **kw})

    def test_a_turn_ends_done(self):
        out = self.stop("Rebased onto main.\n\nWant me to push?")
        self.assertEqual(out.stdout, "")
        state = self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))
        self.assertEqual(session(state, self.sid)["reason"], "Rebased onto main.")

    def test_turn_is_the_registered_sessions_after_a_clear_left_the_hook_an_old_id(self):
        self.hook("Stop", session_id="before-clear", CLAUDE_PID=str(self.proc.pid))
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))

    def test_agent_work_in_flight_is_working_until_it_reports(self):
        self.stop("The review runs in the background.", background_tasks=[{"type": "subagent", "description": "Review the hub"}])
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working" and s["doing"] == "Review the hub"))
        self.stop("Reviewed.")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))

    def test_agent_work_in_flight_keeps_it_working_even_after_a_question(self):
        self.stop("Want me to push meanwhile?", background_tasks=[{"type": "workflow", "description": "Review"}])
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working" and s["doing"] == "Review"))

    def test_a_shell_task_its_closing_words_wait_on_keeps_it_working(self):
        self.stop("The build runs; I'll be notified when it finishes.", background_tasks=[{"type": "shell", "description": "nix build"}])
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working" and s["doing"] == "nix build"))

    def test_a_shell_task_is_done_unless_its_closing_words_say_it_waits(self):
        self.stop("The preview is up at http://localhost:4321.", background_tasks=[{"type": "shell", "description": "preview"}])
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))

    def test_a_turn_that_died_on_an_api_error_failed_with_it_as_the_reason(self):
        self.hook("StopFailure", payload={"error": "rate_limit", "last_assistant_message": "API Error: Rate limit reached"})
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "failed" and s["reason"] == "API Error: Rate limit reached"))

    def test_a_prompt_starts_a_turn(self):
        # The registry's `idle` from setUp must have landed, or it would end this turn as interrupted.
        self.settled()
        self.hook("UserPromptSubmit", payload={"prompt": "build it"})
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))

    def peer_turn(self, closing, name="Stop"):
        """A peer's message wakes the session, as Claude reports it, and its turn ends on `closing`."""
        text = "<cross-session-message from=\"uds:/x\" from-name=\"other\">\nhi\n</cross-session-message>"
        self.hook("UserPromptSubmit", payload={"prompt": text})
        self.hook(name, payload={"last_assistant_message": closing})

    def test_a_peers_message_leaves_your_finished_turn_alone(self):
        self.stop("Want me to push?")
        before = session(self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done")), self.sid)
        self.peer_turn("No action needed from me.")
        after = self.settled()
        self.assertEqual((after["state"], after["reason"], after["since"]), ("done", "Want me to push?", before["since"]))

    def test_a_peers_turn_that_failed_shows_as_a_turn_of_its_own(self):
        self.stop("Rebased.")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))
        self.peer_turn("API Error: overloaded", name="StopFailure")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "failed" and s["reason"] == "API Error: overloaded"))

    def test_a_prompt_that_only_quotes_the_tag_is_yours(self):
        self.settled()
        self.hook("UserPromptSubmit", payload={"prompt": "x" * 300 + ' <cross-session-message from="a">'})
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))

    def test_a_turn_only_the_registry_heard_of_starts_after_its_grace(self):
        self.stop("Want me to push?")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))
        self.hub.write_session(self.proc.pid, self.sid, status="busy")
        self.assertEqual(self.settled()["state"], "done")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))

    def test_a_turn_still_running_across_a_restart_stays_working_until_its_stop(self):
        self.hub.write_session(self.proc.pid, self.sid, status="busy")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))
        self.hub.restart()
        bar = self.hub.connect()
        bar.send(op="subscribe")
        state = bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))
        self.assertFalse(session(state, self.sid)["pulse"])
        self.stop()
        bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))

    def test_nothing_is_kept_across_a_restart_and_nothing_pulses(self):
        self.stop("Want me to push?")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))
        self.hub.restart()
        bar = self.hub.connect()
        bar.send(op="subscribe")
        state = bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))
        self.assertFalse(session(state, self.sid)["pulse"] if "pulse" in session(state, self.sid) else False)
        self.assertFalse((self.hub.tmp / "state" / "agent-hub" / "state.json").exists())

    def test_dialog_that_only_shows_something_leaves_the_turn_alone(self):
        self.stop("The build fails on darwin still.")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))
        self.bar.send(op="dismiss", session=self.sid)
        state = self.bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))
        since = session(state, self.sid)["since"]
        # Claude marks the history view `waiting` too, then stamps its close; neither is this turn's.
        self.hub.write_session(self.proc.pid, self.sid, status="waiting", waitingFor="dialog open", since=since + 5_000)
        self.assertEqual(self.settled()["state"], "idle")
        self.hub.write_session(self.proc.pid, self.sid, status="idle", since=since + 9_000)
        for _ in range(2):
            row = self.settled()
            self.assertEqual((row["state"], row["since"]), ("idle", since))

    def test_a_waiting_session_is_asking_with_the_registrys_reason(self):
        self.hub.write_session(self.proc.pid, self.sid, status="waiting", waitingFor="permission prompt")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "asking" and s["waitingFor"] == "permission prompt"))

    def test_a_dismissed_prompt_stays_away_until_there_is_a_new_one(self):
        self.settled()
        self.hub.write_session(self.proc.pid, self.sid, status="waiting", waitingFor="permission prompt")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "asking"))
        self.bar.send(op="dismiss", session=self.sid)
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))
        self.bar.send(op="undo")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "asking" and not s["pulse"]))


class HiddenTest(HubTest):
    """A session an agent spawned, tracked but kept off the bar."""

    @unittest.skipUnless(Path("/proc/self/environ").exists(), "the hub reads environments from /proc")
    def test_claude_reads_its_environment_when_it_first_sees_it(self):
        bar = self.hub.subscribe()
        self.hub.write_session(self.hub.process(AGENT_HUB_HIDDEN="1").pid, self.sid, status="busy")
        state = bar.wait(lacks_session(self.sid))
        self.assertEqual(state["hidden"], 1)

    def test_a_hook_says_so_where_there_is_no_proc(self):
        bar = self.hub.subscribe()
        self.hub.write_session(self.hub.process().pid, self.sid, status="idle")
        bar.wait(has_session(self.sid))
        event = {"hook_event_name": "UserPromptSubmit", "session_id": self.sid, "prompt": "go"}
        self.hub.command("hook", stdin=json.dumps(event), AGENT_HUB_HIDDEN="1")
        self.assertEqual(bar.wait(lacks_session(self.sid))["hidden"], 1)

    def test_a_session_that_is_not_hidden_shows(self):
        bar = self.hub.subscribe()
        self.hub.write_session(self.hub.process().pid, self.sid, status="busy")
        self.assertEqual(bar.wait(has_session(self.sid))["hidden"], 0)


class ProtocolTest(HubTest):
    def test_a_bad_message_gets_an_error_and_the_connection_stays(self):
        client = self.hub.connect()
        client.send(op="nonsense")
        self.assertIn("unknown op", client.wait(lambda m: m["type"] == "error")["error"])
        client.send(op="subscribe")
        client.wait(lambda m: m["type"] == "state")

    def test_the_hook_does_nothing_for_an_event_it_does_not_take_and_with_no_hub(self):
        for name in ("SessionStart", "PermissionRequest", "SessionEnd"):
            out = self.hub.command("hook", stdin=json.dumps({"hook_event_name": name, "session_id": self.sid}))
            self.assertEqual(out.stdout, "")
        self.hub.kill()
        self.hub.command("hook", stdin=json.dumps({"hook_event_name": "Stop", "session_id": self.sid}))

    def test_demo_shows_the_five_states(self):
        bar = self.hub.subscribe()
        demo = self.hub.connect()
        demo.send(op="demo", sessions=__import__("agent_hub.cli", fromlist=["x"]).demo_sessions())
        state = bar.wait(lambda m: m["type"] == "state" and len({s["state"] for s in m["sessions"]}) == 5)
        self.assertEqual({s["state"] for s in state["sessions"]}, {"asking", "failed", "done", "working", "idle"})
        demo.close()
        bar.wait(lambda m: m["type"] == "state" and not m["sessions"])


class AlertTest(HubTest):
    """What the bar's dot does, end to end."""

    def setUp(self):
        super().setUp()
        self.proc = self.hub.process()
        self.bar = self.hub.subscribe()
        self.at = int(time.time() * 1000)
        self.pi(status="idle")
        self.bar.wait(has_session(self.sid))

    def pi(self, status, **fields):
        self.at += 10
        self.hub.write_session(self.proc.pid, self.sid, status=status, entrypoint="pi", since=self.at, **fields)

    def busy(self):
        self.pi(status="busy")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))

    def fails(self):
        self.busy()
        self.pi(status="idle", hubFailed="boom")
        return self.bar.wait(has_session(self.sid, lambda s: s["state"] == "failed"))

    def test_a_failure_pulses_until_the_popout_opens(self):
        self.assertTrue(session(self.fails(), self.sid)["pulse"])
        self.bar.send(op="seen")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "failed" and not s["pulse"]))

    def test_a_done_turn_pulses_once(self):
        self.busy()
        self.pi(status="idle")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done" and s["pulse"]))
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done" and not s["pulse"]))


# Stands in for `ssh -T -F config host agent-hub attach`: runs the real attach against the host's hub.
FAKE_SSH = """#!{python}
import os, sys
host = sys.argv[sys.argv.index("-F") + 2]
os.environ["XDG_RUNTIME_DIR"] = {runtimes!r} + "/" + host
os.environ["XDG_STATE_HOME"] = {runtimes!r} + "/" + host + "-state"
with open({log!r}, "a") as log:
    log.write(" ".join(sys.argv[1:]) + "\\n")
if os.path.exists({runtimes!r} + "/" + host + ".fail"):
    sys.exit(open({runtimes!r} + "/" + host + ".fail").read())
os.chdir({package!r})
os.execv(sys.executable, [sys.executable, "-m", "agent_hub", "attach"])
"""


def git_repo(path):
    """A git repo with one commit; returns its path."""
    path.mkdir(parents=True)
    subprocess.run(["git", "-C", str(path), "init", "-q", "-b", "main"], check=True)
    (path / "a").write_text("a")
    subprocess.run(["git", "-C", str(path), "add", "a"], check=True)
    subprocess.run(["git", "-C", str(path), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "one"], check=True)
    return path


class LinkTest(unittest.TestCase):
    """A viewer hub with another host's hub piped in, through the real read-only `attach`."""

    def setUp(self):
        self.far = Hub()
        self.addCleanup(self.far.stop)
        self.tmp = Path(tempfile.mkdtemp(prefix="agent-hub-link-"))
        (self.tmp / "far").symlink_to(self.far.socket.parent.parent)
        self.ssh_log = self.tmp / "ssh.log"
        ssh = self.tmp / "ssh"
        ssh.write_text(FAKE_SSH.format(python=sys.executable, runtimes=str(self.tmp), log=str(self.ssh_log), package=str(PACKAGE)))
        ssh.chmod(0o755)
        self.near = Hub(extra={"remotes": ["far"], "ssh": str(ssh), "sshConfig": "/dev/null"})
        self.addCleanup(self.near.stop)
        self.sid = str(uuid.uuid4())
        self.bar = self.near.subscribe()
        self.proc = self.far.process()
        self.far_bar = self.far.subscribe()
        self.at = int(time.time() * 1000)
        self.pi(status="idle")
        self.rid = f"far:{self.sid}"
        self.bar.wait(has_session(self.rid))

    def pi(self, status, **fields):
        self.at += 10
        self.far.write_session(self.proc.pid, self.sid, status=status, entrypoint="pi", cwd="/far/repo", since=self.at, **fields)

    def fails(self, reason="The build broke.", **fields):
        self.pi(status="busy", **fields)
        self.far_bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))
        self.pi(status="idle", hubFailed=reason, **fields)
        return self.bar.wait(has_session(self.rid, lambda s: s["state"] == "failed"))

    def test_a_session_on_another_host_shows_stamped_by_the_viewer(self):
        row = session(self.fails(), self.rid)
        self.assertEqual((row["host"], row["pid"], row["window"], row["reason"]), ("far", None, None, "The build broke."))
        self.assertTrue(row["pulse"])

    def test_the_link_goes_through_its_own_ssh_config_and_says_it_is_up(self):
        state = self.fails()
        self.assertEqual(state["links"], [{"host": "far", "status": "up"}])
        self.assertIn("-T -F /dev/null far agent-hub attach", self.ssh_log.read_text())

    def test_a_viewer_hides_an_ending_at_the_viewer_only(self):
        row = session(self.fails(), self.rid)
        self.bar.send(op="dismiss", session=self.rid, turn=row["turn"] - 1)
        self.bar.send(op="dismiss", session=self.rid, turn=row["turn"])
        self.bar.wait(has_session(self.rid, lambda s: s["state"] == "idle"))
        # The far host is told nothing: its own bar still has it.
        state = self.far_bar.wait(has_session(self.sid, lambda s: s["state"] == "failed"))
        self.assertEqual(session(state, self.sid)["state"], "failed")
        # A newer ending shows again.
        self.assertEqual(session(self.fails("again"), self.rid)["reason"], "again")

    def test_undo_brings_back_what_a_viewer_hid_without_a_pulse(self):
        self.fails()
        self.bar.send(op="dismiss", session=self.rid)
        self.bar.wait(has_session(self.rid, lambda s: s["state"] == "idle"))
        self.bar.send(op="undo")
        row = session(self.bar.wait(has_session(self.rid, lambda s: s["state"] == "failed")), self.rid)
        self.assertFalse(row["pulse"])

    def test_enter_on_a_remote_row_opens_its_tmux_pane_over_ssh_and_hides_its_ending(self):
        self.assertEqual(session(self.fails(tmux="%3"), self.rid)["tmux"], "%3")
        self.bar.send(op="focus", session=self.rid)
        spawn = self.near.focus_log.with_name("focus.log.spawn")
        eventually(lambda: spawn.exists() and spawn.read_text())
        self.assertIn('"ssh", "-t", "far", "tmux", "attach", "-t", "%3"', spawn.read_text())
        self.bar.wait(has_session(self.rid, lambda s: s["state"] == "idle"))

    def test_a_viewer_cannot_send_anything_but_subscribe(self):
        self.fails()
        for message in ({"op": "dismiss", "session": self.sid}, {"op": "focus", "session": self.sid}, {"op": "toggle"},
                        {"op": "turn-end", "session": self.sid, "failure": "x"}):
            self.assertIsNone(links.attach_filter(json.dumps(message)))
        self.assertEqual(links.attach_filter('{"op":"subscribe","version":1}'), {"op": "subscribe", "local": True})
        self.assertEqual(session(self.far_bar.wait(has_session(self.sid)), self.sid)["state"], "failed")


class LinkFailureTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="agent-hub-link-"))
        ssh = self.tmp / "ssh"
        ssh.write_text(FAKE_SSH.format(python=sys.executable, runtimes=str(self.tmp), log=str(self.tmp / "ssh.log"), package=str(PACKAGE)))
        ssh.chmod(0o755)
        (self.tmp / "far.fail").write_text("Permission denied (publickey)\n")
        self.near = Hub(extra={"remotes": ["far"], "ssh": str(ssh), "sshConfig": "/dev/null"})
        self.addCleanup(self.near.stop)

    def test_why_a_link_is_down_is_said(self):
        bar = self.near.connect()
        bar.send(op="subscribe")
        bar.wait(lambda m: m["type"] == "state" and m["links"] == [{"host": "far", "status": "auth failed"}])


class CleanRowTest(unittest.TestCase):
    ID = "11111111-2222-3333-4444-555555555555"

    def row(self, **fields):
        return {"id": self.ID, "state": "done", "name": "n", **fields}

    def test_only_what_is_named_survives_and_the_viewer_stamps_the_host(self):
        row = links.clean_row("far", self.row(pid=99, window=4, prompt="secret", permission={"id": 1}, branch="main", project="repo"))
        self.assertEqual((row["id"], row["host"], row["pid"], row["window"], row["project"]), (f"far:{self.ID}", "far", None, None, "repo"))
        for gone in ("prompt", "permission", "branch", "history", "said"):
            self.assertNotIn(gone, row)

    def test_a_row_that_is_not_one_is_dropped(self):
        self.assertIsNone(links.clean_row("far", self.row(id="../etc")))
        self.assertIsNone(links.clean_row("far", self.row(state="exploding")))

    def test_text_is_one_line_without_control_characters(self):
        row = links.clean_row("far", self.row(name="a\x1b[31m\nb", tmux="%7; rm", bridge="ok_1"))
        self.assertEqual(row["name"], "a [31m b")
        self.assertNotIn("tmux", row)
        self.assertEqual(row["bridge"], "ok_1")


class NiriTest(HubTest):
    """The compositor's socket name carries niri's pid, so a hub started beside it can
    come up without NIRI_SOCKET; it has to find the socket itself."""

    def streamed_socket(self, proc):
        """The socket the daemon's event stream ran with, once it has mapped a window."""
        bar = self.hub.subscribe()
        self.hub.niri({"WindowsChanged": {"windows": [{"id": 9, "pid": proc.pid, "is_focused": False}]}})
        self.hub.write_session(proc.pid, self.sid, status="busy")
        bar.wait(has_session(self.sid, lambda s: s["window"] == 9))
        return self.hub.socket_log.read_text().split()[-1]

    def test_finds_the_compositors_socket_without_niri_socket_in_its_environment(self):
        proc = self.hub.process()
        socket = self.hub.tmp / "run" / f"niri.wayland-1.{proc.pid}.sock"
        socket.touch()
        self.hub.restart()
        self.assertEqual(self.streamed_socket(proc), str(socket))

    def test_a_socket_left_by_a_compositor_that_restarted_is_not_used(self):
        proc = self.hub.process()
        socket = self.hub.tmp / "run" / "niri.wayland-1.999.sock"
        socket.touch()
        self.hub.env["NIRI_SOCKET"] = str(self.hub.tmp / "gone.sock")
        self.hub.restart()
        self.assertEqual(self.streamed_socket(proc), str(socket))


