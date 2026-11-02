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

from agent_hub import protocol

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

# Logs each call as a JSON line; notify-send then holds its "toast" open like --wait.
FAKE_TOOL = """#!{python}
import json, sys, time
with open({log!r}, "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
if {hold!r}:
    print(42, flush=True)
    time.sleep(30)
"""


# Answers with the classification in its answer file, or fails without one; logs the profile it ran as.
FAKE_CLAUDE = """#!{python}
import os, sys
prompt = sys.stdin.read()
with open({log!r}, "a") as log:
    log.write(os.environ.get("CLAUDE_CONFIG_DIR", "-") + "\\n")
with open({log!r} + ".prompts", "a") as log:
    log.write(prompt + "\\n---\\n")
try:
    print(open({answer!r}).read())
except OSError:
    sys.exit(1)
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
    """A daemon on a desktop by default; `headless` drops niri and the toasts, polls the
    registry and leaves it no runtime dir, as on a server or a Mac."""

    def __init__(self, headless=False):
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
        self.toast_log = self.tmp / "toasts.log"
        self.close_log = self.tmp / "close.log"
        tools = {}
        for name, log, hold in (("notify-send", self.toast_log, True), ("busctl", self.close_log, False)):
            tools[name] = self.tmp / name
            tools[name].write_text(FAKE_TOOL.format(python=sys.executable, log=str(log), hold=hold))
            tools[name].chmod(0o755)
        # The fake claude logs each call's profile, and its prompt to `claude.prompts`.
        self.claude_log = self.tmp / "claude.log"
        self.claude_answer = self.tmp / "claude.answer"
        claude = self.tmp / "claude"
        claude.write_text(FAKE_CLAUDE.format(python=sys.executable, log=str(self.claude_log), answer=str(self.claude_answer)))
        claude.chmod(0o755)
        config = self.tmp / "config.json"
        desktop = {"niri": str(niri), "notifySend": str(tools["notify-send"]), "busctl": str(tools["busctl"]),
                   "terminal": ["ghostty", "--working-directory={cwd}", "-e"]}
        config.write_text(json.dumps({
            "registry": str(self.registry),
            "claude": str(claude),
            "git": shutil.which("git"),
            "state": str(self.tmp / "state.json"),
            **({"poll": True} if headless else desktop),
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


# A judge request Pi leaves unanswered, as a model still thinking would.
HOLD = object()


class Pi:
    """A pi session attached to the hub, which answers every reading it is asked for
    with `answer` (None fails it, HOLD never answers), as pi's own side model would. Its
    turns go to a session file the way pi writes them, which is what the hub reads."""

    def __init__(self, hub, sid, pid, answer="", cwd="/repo", **attach):
        self.client = hub.connect()
        self.answer = answer
        self.judged, self.pushed, self.notices, self.replies, self.cancelled, self.refused = [], [], [], {}, [], []
        self.requests = 0
        self.file = hub.tmp / f"pi-{sid}.jsonl"
        self.entries = [{"type": "session", "version": 3, "id": sid, "cwd": cwd}]
        self.changed = threading.Condition()
        threading.Thread(target=self._read, daemon=True).start()
        message = {"version": protocol.VERSION, "session": sid, "pid": pid, "cwd": cwd, "status": "idle",
                   "since": int(time.time() * 1000), "waitingFor": None, "name": None, "record": {},
                   "transcript": str(self.file), "leaf": None, **attach}
        self.client.send(op="attach", **message)

    def _read(self):
        while True:
            try:
                message = self.client.recv(timeout=600)
            except (OSError, ConnectionError, TimeoutError, ValueError):
                return
            with self.changed:
                kind, answer = message.get("type"), self.answer
                if kind == "judge":
                    self.judged.append(message)
                elif kind == "row":
                    self.pushed.append(message)
                elif kind == "reply":
                    self.replies[message["request"]] = message
                elif kind == "notice":
                    self.notices.append(message["text"])
                elif kind == "cancel":
                    self.cancelled.append(message["request"])
                elif kind == "refused":
                    self.refused.append(message["text"])
                self.changed.notify_all()
            if kind == "judge" and answer is not HOLD:
                self.client.send(op="judged", request=message["request"], **({} if answer is None else {"text": answer}))

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

    def end(self, answer=None, said="Done.", pending=0, error=False):
        if answer is not None:
            self.answer = answer
        self._append({"role": "assistant", "content": [{"type": "text", "text": said}]})
        self.client.send(op="turn-end", pending=pending, error=error, transcript=str(self.file))

    def close(self):
        """Hangs up as pi does when its session ends; a shutdown, since the reader thread holds the socket."""
        self.client.sock.shutdown(socket.SHUT_RDWR)


class HubTest(unittest.TestCase):
    def setUp(self):
        self.hub = Hub()
        self.addCleanup(self.hub.stop)
        self.sid = str(uuid.uuid4())


class SessionTest(HubTest):
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
    """A hub with no compositor, no toasts and no runtime dir: the one on a server or a Mac."""

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
        self.assertEqual(self.hub.command("status", "--session-id", "s1").stdout, "working\t\t\n")


class TurnTest(HubTest):
    """How a pi turn ends, as pi's own model read it, and what looking at it does."""

    def setUp(self):
        super().setUp()
        self.proc = self.hub.process()
        self.window = 7
        self.hub.niri({"WindowsChanged": {"windows": [
            {"id": self.window, "pid": self.proc.pid, "is_focused": False},
            {"id": 8, "pid": 1, "is_focused": True},
        ]}})
        self.bar = self.hub.subscribe()
        self.pi = Pi(self.hub, self.sid, self.proc.pid, answer="label: fixture work")
        self.bar.wait(has_session(self.sid, lambda s: s["window"] == self.window))
        self.pi.start()
        # The turn-start reading names it; later answers are the turn's own.
        self.pi.row(lambda push: push["identity"]["label"] == "fixture work")
        self.canaries = 0

    def finish(self, answer):
        self.pi.end(answer)
        expected = {"blocked": "needs-reply", "failed": "failed", "done": "done"}[answer.split("state: ")[1].split()[0]]
        return session(self.bar.wait(has_session(self.sid, lambda s: s["state"] == expected)), self.sid)

    def focused_row(self, window):
        """This session's row, read off a canary write that makes the hub publish."""
        self.hub.niri({"WindowFocusChanged": {"id": window}})
        self.canaries += 1
        canary = self.hub.process()
        self.hub.write_session(canary.pid, "canary", status="busy", name=f"canary {self.canaries}")
        return session(self.bar.wait(has_session("canary")), self.sid)

    def test_pi_turn_ends_as_its_own_model_read_it(self):
        row = self.finish("label: fixture work\nstate: blocked\nask: keep the fixture?\nreply: yes keep it")
        self.assertEqual((row["ask"], row["reply"]), ("keep the fixture?", "yes keep it"))
        self.pi.start()
        row = self.finish("state: failed\ndid: The fixture still breaks the build.")
        self.assertEqual(row["reason"], "The fixture still breaks the build.")

    def test_a_turn_that_ended_on_an_error_failed_whatever_the_model_says(self):
        self.pi.end("state: done", error=True)
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "failed"))

    def test_a_turn_is_read_by_pi_with_the_one_prompt(self):
        self.finish("state: done")
        ask = self.pi.judged[-1]
        self.assertEqual(ask["source"], "session ask")
        self.assertIn("eight lines", ask["system"])
        self.assertIn("assistant said: Done.", ask["prompt"])

    def test_a_turn_whose_reading_fails_ends_by_its_words(self):
        self.pi.answer = None
        self.pi.end(said="Rebased. Want me to push?")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "needs-reply" and s["ask"] == "Want me to push?"))

    def test_a_turn_waiting_on_its_jobs_stays_working(self):
        self.pi.end("state: waiting", pending=1, said="The build runs; I'll be notified when it finishes.")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working" and s["doing"] == "waiting on 1 background job"))

    def test_a_finished_turn_whose_window_has_focus_is_read_and_the_next_one_announces(self):
        self.hub.niri({"WindowFocusChanged": {"id": self.window}})
        self.pi.end("state: done")
        # Looking at it reads the ending, so the row goes idle without a dismissal.
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))
        self.assertFalse(self.hub.toast_log.exists())
        self.pi.start()
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))

    def test_a_finished_turn_under_another_window_stays_until_it_is_read(self):
        self.finish("state: done")
        self.hub.niri({"WindowFocusChanged": {"id": 8}})
        self.hub.niri({"WindowFocusChanged": {"id": self.window}})
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))

    def test_dismissed_turn_is_idle_until_the_next_one_finishes(self):
        self.finish("state: done")
        self.bar.send(op="dismiss", session=self.sid)
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))
        self.pi.start()
        self.finish("state: done")

    def test_a_turn_that_asks_still_wants_you_when_its_window_is_focused(self):
        self.finish("state: blocked\nask: keep the fixture?")
        row = self.focused_row(self.window)
        self.assertEqual((row["state"], row["ask"]), ("needs-reply", "keep the fixture?"))

    def test_a_failed_turn_still_wants_you_when_its_window_is_focused(self):
        self.finish("state: failed")
        self.assertEqual(self.focused_row(self.window)["state"], "failed")

    def test_toggle_dismisses_and_brings_back_the_focused_sessions_turn(self):
        self.finish("state: failed")
        self.hub.niri({"WindowFocusChanged": {"id": self.window}})
        # Focusing closes the turn's toast, which shows the hub has seen the focus.
        logged(self.hub.close_log)
        self.bar.send(op="toggle")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))
        self.bar.send(op="toggle")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "failed"))

    def test_toggle_brings_back_a_done_turn_that_focus_read(self):
        self.hub.niri({"WindowFocusChanged": {"id": self.window}})
        self.pi.end("state: done")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))
        self.bar.send(op="toggle")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))
        self.assertEqual(self.focused_row(self.window)["state"], "done")

    def test_turn_that_ends_unwatched_toasts_until_its_window_is_focused(self):
        self.finish("state: done")
        self.assertIn("Done: fixture work", logged(self.hub.toast_log)[0])
        self.hub.niri({"WindowFocusChanged": {"id": self.window}})
        self.assertEqual(logged(self.hub.close_log)[0][-1], "42")

    def test_a_new_turn_cancels_the_reading_of_the_last_ones_ending(self):
        self.pi.answer = HOLD
        self.pi.end()
        self.pi.wait(lambda: any(j["source"] == "session ask" for j in self.pi.judged))
        held = [j for j in self.pi.judged if j["source"] == "session ask"][-1]["request"]
        self.pi.answer = "label: fixture work"
        self.pi.start(prompt="ok")
        self.pi.wait(lambda: held in self.pi.cancelled)
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working" and s["doing"] != "reading the turn"))

    def test_each_ending_goes_to_the_rows_history_and_the_work_log(self):
        self.finish("state: blocked\nask: keep the fixture?\ndid: Regenerated the fixture.")
        self.pi.start()
        row = self.finish("state: done\ndid: Kept the old fixture.")
        self.assertEqual([(h["state"], h["did"]) for h in row["history"]],
                         [("needs-reply", "Regenerated the fixture."), ("done", "Kept the old fixture.")])
        out = self.hub.command("log", "--since", "1h").stdout.splitlines()
        self.assertEqual(out[0], f"fixture work\tcd /repo && pi --session {self.sid[:8]}")
        self.assertRegex(out[1], r"needs-reply +Regenerated the fixture\. \[asks: keep the fixture\?\]$")
        self.assertRegex(out[2], r"done +Kept the old fixture\.$")
        self.assertEqual(self.hub.command("find", "old", "FIXTURE").stdout.splitlines(), out)
        self.assertEqual(self.hub.command("find", "darwin").stdout, "")


        self.bar.send(op="focus", session=self.sid)
        eventually(lambda: self.hub.focused() == [str(self.window)])


def prompt(text):
    return {"type": "user", "message": {"role": "user", "content": text}}


def said(text):
    return {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}


def ran(job=None):
    """A tool call and its result; `job` makes it a background job that hasn't reported back."""
    result = {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1"}]},
              "toolUseResult": {"backgroundTaskId": job} if job else {"stdout": ""}}
    use = {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t1", "name": "Bash"}]}}
    return [use, result]


def reported(job):
    return {"type": "queue-operation", "operation": "enqueue",
            "content": f"<task-notification>\n<task-id>{job}</task-id>\n<status>completed</status>"}


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

    def stop(self, entries, session_id=None, **env):
        transcript = self.hub.write_transcript(self.sid, entries)
        event = {"hook_event_name": "Stop", "session_id": session_id or self.sid, "transcript_path": str(transcript)}
        self.hub.command("hook", stdin=json.dumps(event), **env)

    def test_turn_that_ends_on_a_question_needs_a_reply(self):
        self.stop([prompt("rebase it"), said("Rebased onto main.\n\nWant me to push?")])
        state = self.bar.wait(has_session(self.sid, lambda s: s["state"] == "needs-reply" and s["ask"] == "Want me to push?"))
        self.assertEqual(session(state, self.sid)["summary"], "Rebased onto main.")

    def test_a_turn_is_read_before_it_shows_and_is_working_meanwhile(self):
        # A guess read off the turn's words would show `done` first, then the model's verdict
        # overrules it, announcing one turn end twice.
        self.hub.claude_answer.write_text("state: blocked\nask: keep the old fixture?\ndid: Regenerated the fixture.\n")
        bar = self.hub.subscribe()
        self.stop([prompt("regenerate the fixture"), *ran(), said("Regenerated; the build is green.")])
        states = []
        while True:
            message = bar.recv()
            if message["type"] != "state" or (row := session(message, self.sid)) is None:
                continue
            states.append(row["state"])
            if row["state"] == "needs-reply":
                break
        self.assertEqual(states[-2:], ["working", "needs-reply"])
        self.assertEqual(logged(self.hub.toast_log)[0][-2:], ["demo asks", "keep the old fixture?"])

    def test_turn_is_the_registered_sessions_after_a_clear_left_the_hook_an_old_id(self):
        self.stop([prompt("rebase it"), said("Want me to push?")], session_id="before-clear", CLAUDE_PID=str(self.proc.pid))
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "needs-reply"))

    def test_turn_that_waits_on_its_background_job_is_working_until_the_job_reports(self):
        job = [prompt("build it"), *ran("b1"), said("The build runs in the background; I'll be notified when it finishes.")]
        self.stop(job)
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working" and s["doing"] == "waiting on 1 background job"))
        self.stop([*job, reported("b1"), said("Built.")])
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))

    def test_background_server_left_running_does_not_keep_the_session_working(self):
        self.stop([prompt("show me the site"), *ran("b1"), said("The preview is up at http://localhost:4321.")])
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))

    def test_claude_decides_whether_a_turn_waits_on_its_jobs(self):
        self.hub.claude_answer.write_text("state: done\nask:\ndid: Started the preview server.\n")
        self.stop([prompt("show me the site"), *ran("b1"), said("Started it; waiting for you to look.")])
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done" and s["summary"] == "Started the preview server."))

    def test_long_turn_is_put_to_claude_as_the_sessions_profile(self):
        self.hub.claude_answer.write_text("state: failed\nask: empty\ndid: The build still fails on darwin.\n")
        self.stop([prompt("fix the build"), *ran(), said("I changed the overlay.")], CLAUDE_CONFIG_DIR="/profiles/work")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "failed" and s["summary"] == "The build still fails on darwin."))
        self.assertEqual(self.hub.claude_log.read_text().split(), ["/profiles/work"])

    def test_finished_turn_survives_a_restart(self):
        self.stop([prompt("rebase it"), said("Want me to push?")])
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "needs-reply"))
        self.hub.restart()
        bar = self.hub.connect()
        bar.send(op="subscribe")
        bar.wait(has_session(self.sid, lambda s: s["state"] == "needs-reply"))

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
    """An attached pi session: its own status, name and identity, and what the hub asks of it."""

    def setUp(self):
        super().setUp()
        self.proc = self.hub.process()
        self.bar = self.hub.subscribe()

    def attach(self, answer="label: retry flakes", **attach):
        return Pi(self.hub, self.sid, self.proc.pid, answer=answer, **attach)

    def test_attached_session_shows_without_a_registry_entry_and_drops_when_it_hangs_up(self):
        pi = self.attach()
        self.bar.wait(has_session(self.sid))
        pi.close()
        self.bar.wait(lacks_session(self.sid))

    def test_turn_start_names_the_work_and_the_step_and_pushes_them_to_pi(self):
        pi = self.attach(answer="label: Retry Flakes!\ndoing: rerunning the retry test\ntags: test, ci")
        pi.start()
        row = self.bar.wait(has_session(self.sid, lambda s: s["label"] == "Retry Flakes" and s["doing"]))
        self.assertEqual((session(row, self.sid)["name"], session(row, self.sid)["reason"]),
                         ("Retry Flakes", "rerunning the retry test"))
        push = pi.row(lambda p: p["identity"]["tags"] == ["test", "ci"])
        self.assertEqual(push["identity"]["label"], "Retry Flakes")
        self.assertEqual(pi.judged[0]["source"], "session label")

    def test_a_turn_not_worth_naming_asks_nothing(self):
        pi = self.attach()
        pi.start(prompt="ok thanks")
        pi.start(prompt="a steer", from_person=False)
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))
        self.assertEqual(pi.judged, [])

    def test_the_persons_own_name_outranks_the_label(self):
        pi = self.attach(name="my name")
        pi.start()
        pi.row(lambda p: p["identity"]["label"] == "retry flakes")
        self.assertEqual(session(self.bar.wait(has_session(self.sid)), self.sid)["name"], "my name")
        pi.client.send(op="named", name=None)
        self.bar.wait(has_session(self.sid, lambda s: s["name"] == "retry flakes"))

    def test_record_on_attach_is_the_identity_until_a_reading_changes_it(self):
        self.attach(record={"label": "kept label", "summary": "From the branch.", "calls": 3})
        self.bar.wait(has_session(self.sid, lambda s: s["label"] == "kept label"))

    def test_dialog_asks_with_its_label_until_it_closes(self):
        pi = self.attach()
        pi.start()
        pi.client.send(op="dialog", text="bash: rm -rf build")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "asking" and s["reason"] == "bash: rm -rf build"))
        pi.client.send(op="dialog", text=None)
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))

    def test_relabel_that_fails_is_reported_to_pi(self):
        pi = self.attach(answer=None)
        pi.start(prompt="ok")
        pi.client.send(op="relabel")
        pi.wait(lambda: pi.notices)
        self.assertEqual(pi.notices, ["identity: relabel failed"])

    def test_session_that_ended_is_recent_with_the_command_that_resumes_it(self):
        pi = self.attach(cwd="/home/me/repo")
        pi.start()
        pi.row(lambda p: p["identity"]["label"] == "retry flakes")
        pi.close()
        state = self.bar.wait(lambda m: m["type"] == "state" and m["recent"])
        self.assertEqual(state["recent"][0]["resume"], f"cd /home/me/repo && pi --session {self.sid[:8]}")
        self.assertEqual(self.hub.command("recent").stdout, f"retry flakes\tcd /home/me/repo && pi --session {self.sid[:8]}\n")

    def test_resume_opens_a_terminal_on_the_command_through_niri(self):
        pi = self.attach(cwd="/home/me/repo")
        pi.start()
        pi.row(lambda p: p["identity"]["label"] == "retry flakes")
        pi.close()
        self.bar.wait(lambda m: m["type"] == "state" and m["recent"])
        self.bar.send(op="resume", session=self.sid)
        spawned = logged(Path(str(self.hub.focus_log) + ".spawn"))
        self.assertEqual(spawned, [["ghostty", "--working-directory=/home/me/repo", "-e", "pi", "--session", self.sid[:8]]])

    def test_resumed_session_takes_its_label_back_off_the_recent_list(self):
        pi = self.attach()
        pi.start()
        pi.row(lambda p: p["identity"]["label"] == "retry flakes")
        pi.close()
        self.bar.wait(lambda m: m["type"] == "state" and m["recent"])
        self.attach(answer="")
        state = self.bar.wait(has_session(self.sid, lambda s: s["label"] == "retry flakes"))
        self.assertEqual(state["recent"], [])


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
    """A Claude Code session named by `claude -p` as its own profile, from its hooks."""

    def setUp(self):
        super().setUp()
        self.proc = self.hub.process()
        self.bar = self.hub.subscribe()
        self.hub.write_session(self.proc.pid, self.sid, status="busy", name="repo-12", nameSource="derived")
        self.bar.wait(has_session(self.sid))
        self.transcript = self.hub.write_transcript(self.sid, [prompt("fix the build"), *ran(), said("Fixed.")])
        self.hub.claude_answer.write_text("label: fix the darwin build\ndoing: reading the overlay\n")

    def hook(self, name, **env):
        event = {"hook_event_name": name, "session_id": self.sid, "cwd": "/repo", "transcript_path": str(self.transcript),
                 "prompt": "and the eval", "source": "startup"}
        return self.hub.command("hook", stdin=json.dumps(event), **env).stdout

    def test_prompt_names_the_session_from_its_transcript_and_the_new_prompt(self):
        self.hook("UserPromptSubmit")
        self.bar.wait(has_session(self.sid, lambda s: s["name"] == "fix the darwin build" and s["doing"] == "reading the overlay"))
        asked = (self.hub.claude_log.with_suffix(".log.prompts")).read_text()
        self.assertIn("- fix the build\n- and the eval", asked)

    def test_session_start_names_the_profile_its_readings_run_as(self):
        self.hook("SessionStart", CLAUDE_CONFIG_DIR="/profiles/.claude-work")
        self.hook("UserPromptSubmit")
        self.bar.wait(has_session(self.sid, lambda s: s["label"] == "fix the darwin build"))
        self.assertEqual(self.hub.claude_log.read_text().split(), ["/profiles/.claude-work"])

    def test_ended_session_resumes_under_its_profile_and_takes_its_label_back(self):
        self.hook("SessionStart", CLAUDE_CONFIG_DIR="/profiles/.claude-work")
        self.hook("UserPromptSubmit")
        self.bar.wait(has_session(self.sid, lambda s: s["label"] == "fix the darwin build"))
        self.proc.kill()
        self.proc.wait()
        state = self.bar.wait(lambda m: m["type"] == "state" and m["recent"])
        self.assertEqual(state["recent"][0]["resume"], f"cd /repo && claude-work --resume {self.sid}")
        again = self.hub.process()
        self.hook("SessionStart", CLAUDE_CONFIG_DIR="/profiles/.claude-work")
        self.hub.write_session(again.pid, self.sid, status="idle", name="repo-12", nameSource="derived")
        state = self.bar.wait(has_session(self.sid, lambda s: s["name"] == "fix the darwin build"))
        self.assertEqual(state["recent"], [])

    def test_a_session_its_hooks_named_before_the_registry_lives_until_its_session_end(self):
        live = self.hub.process()
        event = {"hook_event_name": "UserPromptSubmit", "session_id": "early", "cwd": "/repo",
                 "transcript_path": str(self.transcript), "prompt": "and the eval"}
        self.hub.command("hook", stdin=json.dumps(event), CLAUDE_PID=str(live.pid))
        state_file = self.hub.tmp / "state.json"
        eventually(lambda: state_file.exists() and "fix the darwin build" in state_file.read_text())
        self.hub.command("hook", stdin=json.dumps({"hook_event_name": "SessionEnd", "session_id": "early",
                                                   "reason": "prompt_input_exit"}), CLAUDE_PID=str(live.pid))
        state = self.bar.wait(lambda m: m["type"] == "state" and m["recent"])
        self.assertEqual([(r["id"], r["label"]) for r in state["recent"]], [("early", "fix the darwin build")])

    def test_a_name_the_person_chose_outranks_the_label(self):
        self.hub.write_session(self.proc.pid, self.sid, status="busy", name="mine", nameSource="user")
        self.hook("UserPromptSubmit")
        self.bar.wait(has_session(self.sid, lambda s: s["label"] == "fix the darwin build" and s["name"] == "mine"))


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
        event = {"hook_event_name": "PermissionRequest", "session_id": self.sid, "cwd": "/repo",
                 "tool_name": "Bash", "tool_input": {"command": "rm -rf build\n  && make"}}
        self.hub.command("hook", stdin=json.dumps(event))
        self.bar.wait(has_session(self.sid, lambda s: s["waitingFor"] == "Bash: rm -rf build && make"))

    def test_waiting_unwatched_toasts_with_its_label(self):
        self.label("Bash: rm -rf build")
        self.hub.write_session(self.proc.pid, self.sid, status="waiting", waitingFor="permission prompt")
        toast = logged(self.hub.toast_log)[0]
        self.assertEqual(toast[-2:], ["demo needs you", "Bash: rm -rf build"])

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
        self.done = Pi(self.hub, "done", self.procs["done"].pid, answer="state: done")
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
        self.pi = Pi(self.hub, self.sid, self.proc.pid, answer="label: fixture work\nstate: blocked\nask: keep the fixture?")
        self.pi.start()
        self.pi.row(lambda push: push["identity"]["label"] == "fixture work")
        self.pi.end()
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "needs-reply"))

    def status(self, *args):
        return self.hub.command("status", *args).stdout

    def test_prints_the_state_the_reason_and_the_label_for_its_own_session(self):
        self.assertEqual(self.status("--session-id", self.sid), "needs-reply\tkeep the fixture?\tfixture work\n")

    def test_falls_back_to_the_pid_of_a_session_whose_id_the_caller_lost(self):
        self.assertEqual(self.status("--session-id", "before-a-clear", "--pid", str(self.proc.pid)),
                         "needs-reply\tkeep the fixture?\tfixture work\n")

    def test_a_pid_under_the_agent_finds_its_session(self):
        parent = subprocess.Popen([sys.executable, "-c", "import subprocess, sys, time\n"
                                   "child = subprocess.Popen(['sleep', '600'])\nprint(child.pid, flush=True)\ntime.sleep(600)"],
                                  stdout=subprocess.PIPE, text=True)
        self.hub.processes.append(parent)
        child = int(parent.stdout.readline())
        self.addCleanup(os.kill, child, signal.SIGKILL)
        pi = Pi(self.hub, "parent", parent.pid, answer="label: the parent")
        pi.start()
        pi.wait(lambda: any(p["identity"]["label"] == "the parent" for p in pi.pushed))
        self.assertEqual(self.status("--pid", str(child)), "working\t\tthe parent\n")

    def test_json_is_the_hubs_row(self):
        row = json.loads(self.status("--json", "--session-id", self.sid))
        self.assertEqual((row["state"], row["ask"], row["label"]), ("needs-reply", "keep the fixture?", "fixture work"))

    def test_prints_nothing_for_a_session_the_hub_does_not_know(self):
        self.assertEqual(self.status("--session-id", "nobody"), "")
        self.assertEqual(self.status("--pid", "1"), "")

    def test_prints_nothing_when_the_hub_is_down(self):
        self.hub.daemon.kill()
        self.hub.daemon.wait()
        self.assertEqual(self.status("--session-id", self.sid), "")


if __name__ == "__main__":
    unittest.main()
