"""Digest tests: synthetic pi session files, read back through `pi.digest`."""

import json
import shutil
import tempfile
import unittest
from pathlib import Path

from agent_hub import pi

CWD = "/work/repo"


class Session:
    """A pi session file built entry by entry; each entry is a child of `parent`, by
    default the one appended before it."""

    def __init__(self, path):
        self.path = path
        self.entries = [{"type": "session", "version": 3, "id": "sess", "cwd": CWD}]
        self.last = None

    def add(self, message, parent=...):
        entry = {"type": "message", "id": f"e{len(self.entries)}",
                 "parentId": self.last if parent is ... else parent, "message": message}
        self.entries.append(entry)
        self.last = entry["id"]
        self.path.write_text("".join(json.dumps(e) + "\n" for e in self.entries))
        return entry["id"]

    def user(self, text, **kw):
        return self.add({"role": "user", "content": [{"type": "text", "text": text}]}, **kw)

    def assistant(self, text="", calls=(), **kw):
        content = [{"type": "text", "text": text}] if text else []
        content += [{"type": "toolCall", "id": cid, "name": name, "arguments": args} for cid, name, args in calls]
        return self.add({"role": "assistant", "content": content}, **kw)

    def result(self, call, error=False, **kw):
        return self.add({"role": "toolResult", "toolCallId": call, "isError": error,
                         "content": [{"type": "text", "text": "output"}]}, **kw)

    def peer(self):
        entry = {"type": "custom_message", "customType": pi.PEER_MESSAGE, "id": f"e{len(self.entries)}", "parentId": self.last, "content": "hi"}
        self.entries.append(entry)
        self.last = entry["id"]
        self.path.write_text("".join(json.dumps(e) + "\n" for e in self.entries))


class DigestTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="agent-hub-pi-test-"))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.session = Session(self.tmp / "session.jsonl")

    def digest(self, **kw):
        return pi.digest(self.session.path, **kw)

    def test_follows_the_branch_to_its_leaf(self):
        s = self.session
        root = s.user("fix the login form")
        s.assistant("Trying one way.", [("c1", "edit", {"path": "abandoned.py"})])
        s.user("try another approach", parent=root)
        leaf = s.assistant("Done the other way.", [("c2", "edit", {"path": "kept.py"})])
        s.user("never mind", parent=root)
        d = self.digest(leaf=leaf)
        self.assertEqual(d["requests"], ["fix the login form", "try another approach"])
        self.assertEqual(d["files"], ["kept.py"])
        self.assertEqual(d["said"], "Done the other way.")

    def test_without_a_leaf_reads_the_last_entry_appended(self):
        s = self.session
        root = s.user("fix the login form")
        s.assistant("One way.")
        s.user("start over", parent=root)
        self.assertEqual(self.digest()["requests"], ["fix the login form", "start over"])

    def test_an_unknown_leaf_falls_back_to_the_last_entry(self):
        self.session.user("fix the login form")
        self.assertEqual(self.digest(leaf="gone")["requests"], ["fix the login form"])

    def test_acknowledgements_are_not_requests(self):
        s = self.session
        s.user("rename the config loader")
        s.user("ok thanks")
        s.user("sounds good, but make it async")
        self.assertEqual(self.digest()["requests"], ["rename the config loader", "sounds good, but make it async"])

    def test_keeps_the_first_request_and_the_latest(self):
        for n in range(8):
            self.session.user(f"request {n}\n  with   detail")
        self.assertEqual(self.digest()["requests"],
                         ["request 0 with detail"] + [f"request {n} with detail" for n in range(4, 8)])

    def test_requests_are_cut(self):
        self.session.user("x" * 1000)
        self.assertEqual(len(self.digest()["requests"][0]), 300)

    def test_commands_carry_their_outcome(self):
        s = self.session
        s.user("run the tests")
        s.assistant(calls=[("ok", "bash", {"command": "\n  just test  \nmore"}),
                           ("bad", "bg_run", {"command": "just build"}),
                           ("open", "bash", {"command": "sleep 1"}),
                           ("r", "read", {"path": "x"})])
        s.result("ok")
        s.result("bad", error=True)
        self.assertEqual(self.digest()["commands"], ["just test (ok)", "just build (failed)", "sleep 1"])

    def test_commands_keep_the_last_five_cut_short(self):
        s = self.session
        s.user("run things")
        s.assistant(calls=[(f"c{n}", "bash", {"command": f"echo {n} " + "y" * 100}) for n in range(7)])
        commands = self.digest()["commands"]
        self.assertEqual(len(commands), 5)
        self.assertTrue(commands[0].startswith("echo 2 "))
        self.assertEqual(len(commands[0]), 48)

    def test_files_are_relative_to_the_session_cwd(self):
        s = self.session
        s.user("edit things")
        s.assistant(calls=[("a", "edit", {"path": f"{CWD}/src/a.py"}),
                           ("b", "write", {"path": "./src/b.py"}),
                           ("c", "edit", {"path": "@src/c.py"}),
                           ("d", "write", {"path": "/elsewhere/d.py"}),
                           ("e", "edit", {"path": "src/a.py"}),
                           ("f", "read", {"path": "src/read.py"})])
        self.assertEqual(self.digest()["files"], ["src/b.py", "src/c.py", "/elsewhere/d.py", "src/a.py"])

    def test_cwd_overrides_the_sessions(self):
        s = self.session
        s.user("edit")
        s.assistant(calls=[("a", "edit", {"path": f"{CWD}/src/a.py"})])
        self.assertEqual(self.digest(cwd=f"{CWD}/src")["files"], ["a.py"])

    def test_files_keep_the_last_six(self):
        s = self.session
        s.user("edit")
        s.assistant(calls=[(str(n), "write", {"path": f"f{n}"}) for n in range(9)])
        self.assertEqual(self.digest()["files"], [f"f{n}" for n in range(3, 9)])

    def test_said_is_the_last_assistant_text_of_the_turn(self):
        s = self.session
        s.user("look into it")
        s.assistant("First thoughts.")
        s.assistant("All done, shall I commit?", [("c", "bash", {"command": "git status"})])
        s.result("c")
        s.assistant("")
        d = self.digest()
        self.assertEqual(d["said"], "All done, shall I commit?")

    def test_files_and_commands_are_the_latest_turns_alone(self):
        s = self.session
        s.user("first job")
        s.assistant(calls=[("a", "edit", {"path": "old.py"}), ("b", "bash", {"command": "just old"})])
        s.user("second job")
        s.assistant(calls=[("c", "edit", {"path": "new.py"})])
        d = self.digest()
        self.assertEqual((d["files"], d["commands"]), (["new.py"], []))

    def test_before_a_new_prompt_the_turn_before_still_says_what_the_work_is(self):
        s = self.session
        s.user("first job")
        s.assistant(calls=[("a", "edit", {"path": "old.py"})])
        d = self.digest(prompt="second job")
        self.assertEqual((d["files"], d["requests"]), (["old.py"], ["first job", "second job"]))

    def test_a_peers_message_starts_a_turn_marked_as_one(self):
        s = self.session
        s.user("first job")
        s.assistant("Done, shall I commit?")
        s.peer()
        d = self.digest()
        self.assertEqual((d["peer"], d["said"], d["requests"]), (True, "", ["first job"]))

    def test_appends_a_prompt_not_yet_on_the_file(self):
        self.session.user("fix the login form")
        self.assertEqual(self.digest(prompt="now  the\nsignup form")["requests"],
                         ["fix the login form", "now the signup form"])
        self.assertEqual(self.digest(prompt="yes please")["requests"], ["fix the login form"])

    def test_a_file_pi_has_not_written_yet_reads_as_its_prompt(self):
        d = pi.digest(self.tmp / "missing.jsonl", prompt="fix the login form")
        self.assertEqual(d["requests"], ["fix the login form"])
        self.assertIsNone(pi.digest(self.tmp / "missing.jsonl"))

    def test_an_unreadable_file_is_none(self):
        self.assertIsNone(pi.digest(self.tmp, prompt="fix the login form"))

    def test_skips_malformed_lines(self):
        self.session.user("fix the login form")
        with open(self.session.path, "a") as f:
            f.write("{not json\n[1, 2]\n")
        self.assertEqual(self.digest()["requests"], ["fix the login form"])


class AcknowledgementTest(unittest.TestCase):
    def test_bare_agreement(self):
        for text in ("ok", "Yes, please!", "go ahead", "LGTM", "thanks", "carry on"):
            self.assertTrue(pi.is_acknowledgement(text), text)

    def test_anything_more(self):
        for text in ("", "   ", "ok, now add tests", "sounds good but async", "yes do it now please", "fix it"):
            self.assertFalse(pi.is_acknowledgement(text), text)


if __name__ == "__main__":
    unittest.main()
