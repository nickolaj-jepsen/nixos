"""Protocol tests: a real daemon on a temp runtime dir, a temp session registry and
a scripted niri, driven over its socket."""

import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from pathlib import Path

HUB = Path(os.environ.get("AGENT_HUB", Path(__file__).resolve().parent.parent / "agent_hub.py"))
TIMEOUT = 5

FAKE_NIRI = """#!{python}
import sys
args = sys.argv[1:]
if "event-stream" in args:
    with open({fifo!r}) as events:
        for line in events:
            print(line, end="", flush=True)
elif "focus-window" in args:
    with open({log!r}, "a") as log:
        log.write(args[-1] + "\\n")
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
sys.stdin.read()
with open({log!r}, "a") as log:
    log.write(os.environ.get("CLAUDE_CONFIG_DIR", "-") + "\\n")
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
    def __init__(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="agent-hub-test-"))
        self.registry = self.tmp / "sessions"
        self.registry.mkdir()
        fifo = self.tmp / "niri.fifo"
        os.mkfifo(fifo)
        # Read-write so neither side blocks on open, and the stream outlives a reader.
        self.niri_events = os.open(fifo, os.O_RDWR)
        self.focus_log = self.tmp / "focus.log"
        niri = self.tmp / "niri"
        niri.write_text(FAKE_NIRI.format(python=sys.executable, fifo=str(fifo), log=str(self.focus_log)))
        niri.chmod(0o755)
        self.toast_log = self.tmp / "toasts.log"
        self.close_log = self.tmp / "close.log"
        tools = {}
        for name, log, hold in (("notify-send", self.toast_log, True), ("busctl", self.close_log, False)):
            tools[name] = self.tmp / name
            tools[name].write_text(FAKE_TOOL.format(python=sys.executable, log=str(log), hold=hold))
            tools[name].chmod(0o755)
        self.claude_log = self.tmp / "claude.log"
        self.claude_answer = self.tmp / "claude.answer"
        claude = self.tmp / "claude"
        claude.write_text(FAKE_CLAUDE.format(python=sys.executable, log=str(self.claude_log), answer=str(self.claude_answer)))
        claude.chmod(0o755)
        config = self.tmp / "config.json"
        config.write_text(json.dumps({
            "registry": str(self.registry),
            "niri": str(niri),
            "notifySend": str(tools["notify-send"]),
            "busctl": str(tools["busctl"]),
            "claude": str(claude),
            "state": str(self.tmp / "state.json"),
        }))
        runtime = self.tmp / "run"
        runtime.mkdir(mode=0o700)
        self.socket = runtime / "agent-hub" / "hub.sock"
        self.env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), AGENT_HUB_CONFIG=str(config))
        self.env.pop("CLAUDE_CONFIG_DIR", None)
        self.processes = []
        self.clients = []
        self.start()

    def start(self):
        self.daemon = subprocess.Popen([sys.executable, str(HUB), "daemon"], env=self.env)
        deadline = time.monotonic() + TIMEOUT
        while not self.socket.exists():
            if time.monotonic() > deadline or self.daemon.poll() is not None:
                raise RuntimeError("hub did not start")
            time.sleep(0.02)

    def restart(self):
        self.daemon.kill()
        self.daemon.wait()
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
        subprocess.run([sys.executable, str(HUB), *args], env=dict(self.env, **env), input=stdin, text=True, check=True,
                       timeout=TIMEOUT)

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
        self.daemon.kill()
        self.daemon.wait()
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


class TurnTest(HubTest):
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
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working" and s["window"] == self.window))

    def test_pi_turn_leaves_the_state_its_sidecar_reported(self):
        self.hub.write_session(self.proc.pid, self.sid, status="idle", turnState="blocked", ask="keep the fixture?")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "needs-reply" and s["ask"] == "keep the fixture?"))
        self.hub.write_session(self.proc.pid, self.sid, status="idle", turnState="failed")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "failed"))

    def test_finished_turn_stays_done_while_watched_until_the_next_turn(self):
        self.hub.niri({"WindowFocusChanged": {"id": self.window}})
        self.hub.write_session(self.proc.pid, self.sid, status="idle", turnState="done")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))
        self.hub.write_session(self.proc.pid, self.sid, status="busy")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "working"))

    def test_dismissed_turn_is_idle_until_the_next_one_finishes(self):
        self.hub.write_session(self.proc.pid, self.sid, status="idle", turnState="done")
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))
        self.bar.send(op="dismiss", session=self.sid)
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "idle"))
        self.hub.write_session(self.proc.pid, self.sid, status="busy")
        self.hub.write_session(self.proc.pid, self.sid, status="idle", turnState="done", since=int(time.time() * 1000) + 1)
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done"))

    def test_turn_that_ends_unwatched_toasts_until_its_window_is_focused(self):
        self.hub.write_session(self.proc.pid, self.sid, status="idle", turnState="done")
        self.assertIn("Done: demo", logged(self.hub.toast_log)[0])
        self.hub.niri({"WindowFocusChanged": {"id": self.window}})
        self.assertEqual(logged(self.hub.close_log)[0][-1], "42")

    def test_focus_request_focuses_the_sessions_window(self):
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

    def stop(self, entries, **env):
        transcript = self.hub.write_transcript(self.sid, entries)
        event = {"hook_event_name": "Stop", "session_id": self.sid, "transcript_path": str(transcript)}
        self.hub.command("hook", stdin=json.dumps(event), **env)

    def test_turn_that_ends_on_a_question_needs_a_reply(self):
        self.stop([prompt("rebase it"), said("Rebased onto main.\n\nWant me to push?")])
        state = self.bar.wait(has_session(self.sid, lambda s: s["state"] == "needs-reply" and s["ask"] == "Want me to push?"))
        self.assertEqual(session(state, self.sid)["summary"], "Rebased onto main.")

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
        self.hub.claude_answer.write_text("state: done\nask:\nsummary: Started the preview server.\n")
        self.stop([prompt("show me the site"), *ran("b1"), said("Started it; waiting for you to look.")])
        self.bar.wait(has_session(self.sid, lambda s: s["state"] == "done" and s["summary"] == "Started the preview server."))

    def test_long_turn_is_put_to_claude_as_the_sessions_profile(self):
        self.hub.claude_answer.write_text("state: failed\nask: empty\nsummary: The build still fails on darwin.\n")
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
        self.hub.connect().send(op="waiting", session={"id": self.sid}, text=text)

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
        self.hub.write_session(self.procs["done"].pid, "done", status="idle", turnState="done")
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


if __name__ == "__main__":
    unittest.main()
