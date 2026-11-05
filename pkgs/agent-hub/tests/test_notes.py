"""Which notes a session touched, how they read, and the reader's ops on a real daemon."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

from agent_hub import links
from agent_hub.notes import NOTE_MAX, Notes, is_note, labels
from agent_hub.render import render
from test_hub import FAKE_SSH, PACKAGE, Hub, has_session, logged, session


def claude_call(name, call="c1", **args):
    return {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": call, "name": name, "input": args}]}}


def claude_failed(call="c1"):
    return {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": call, "is_error": True, "content": "no"}]}}


def pi_call(name, call="p1", **args):
    return {"type": "message", "message": {"role": "assistant", "content": [{"type": "toolCall", "id": call, "name": name, "arguments": args}]}}


def pi_failed(call="p1"):
    return {"type": "message", "message": {"role": "toolResult", "toolCallId": call, "isError": True, "content": []}}


def write_lines(path, entries, mode="w"):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, mode) as out:
        out.writelines(json.dumps(entry) + "\n" for entry in entries)


class NotesCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="agent-hub-notes-"))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.root = self.tmp / "agents"
        self.notes = Notes([self.root])
        self.transcript = self.tmp / "session.jsonl"

    def note(self, rel, age=0, text="# note\n"):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        stamp = 1_700_000_000 - age
        os.utime(path, (stamp, stamp))
        return str(path)

    def listed(self, project=None, sid="s"):
        return [(n["group"], n["path"]) for n in self.notes.listing(sid, str(self.transcript), "/repo", project)]


class TouchedTest(NotesCase):
    def test_a_note_written_by_a_subagent_counts_as_much_as_the_sessions_own(self):
        own, sub = self.note("p/own.md", 5), self.note("p/report.md", 1)
        write_lines(self.transcript, [claude_call("Write", file_path=own)])
        write_lines(self.tmp / "session" / "subagents" / "agent-1.jsonl", [claude_call("Write", file_path=sub)])
        self.assertEqual(self.listed(), [("written", sub), ("written", own)])

    def test_a_pi_subagents_write_counts_and_a_record_stands_for_a_nested_call(self):
        sub, nested = self.note("p/sub.md", 2), self.note("p/nested.md", 1)
        write_lines(self.transcript, [{"type": "custom", "customType": "agent-note", "data": {"path": nested}}])
        write_lines(self.tmp / "session" / "tasks" / "child.jsonl", [pi_call("write", path=sub)])
        self.assertEqual(self.listed(), [("written", nested), ("written", sub)])

    def test_a_command_writes_what_it_redirects_to_and_only_reads_the_rest(self):
        made, used = self.note("p/made.md", 1), self.note("p/used.md", 2)
        write_lines(self.transcript, [claude_call("Bash", command=f"cat {used} > {made}")])
        self.assertEqual(self.listed(), [("written", made), ("read", used)])

    def test_a_note_only_read_is_listed_after_those_written(self):
        written, read = self.note("p/w.md", 9), self.note("p/HANDOFF.md", 1)
        write_lines(self.transcript, [claude_call("Read", "a", file_path=read), claude_call("Edit", "b", file_path=written)])
        self.assertEqual(self.listed(), [("written", written), ("read", read)])

    def test_a_failed_write_is_not_a_write_unless_another_landed(self):
        failed, landed = self.note("p/a.md", 1), self.note("p/b.md", 2)
        write_lines(self.transcript, [claude_call("Edit", "a", file_path=failed), claude_failed("a"),
                                      pi_call("edit", "b", path=landed), pi_call("edit", "c", path=landed), pi_failed("c")])
        self.assertEqual(self.listed(), [("written", landed)])

    def test_a_note_since_deleted_is_not_listed(self):
        gone = self.note("p/gone.md")
        write_lines(self.transcript, [claude_call("Write", file_path=gone)])
        os.unlink(gone)
        self.assertEqual(self.listed(), [])

    def test_a_path_resolves_as_pis_tools_read_it(self):
        note = self.note("p/rel.md")
        write_lines(self.transcript, [pi_call("write", path=f"@{self.root}/p/x/../rel.md")])
        self.assertEqual(self.listed(), [("written", note)])

    def test_only_what_was_added_since_is_read_and_a_half_written_line_waits(self):
        first, second = self.note("p/1.md", 2), self.note("p/2.md", 1)
        write_lines(self.transcript, [claude_call("Write", "a", file_path=first)])
        self.assertTrue(self.notes.scan("s", str(self.transcript), None))
        line = json.dumps(claude_call("Write", "b", file_path=second))
        with open(self.transcript, "a") as out:
            out.write(line[:20])
        self.assertFalse(self.notes.scan("s", str(self.transcript), None))
        with open(self.transcript, "a") as out:
            out.write(line[20:] + "\n")
        self.assertTrue(self.notes.scan("s", str(self.transcript), None))
        self.assertEqual(self.notes.latest["s"][0]["path"], second)
        self.assertEqual(self.notes.latest["s"][1], 2)


class ListingTest(NotesCase):
    def test_superseded_copies_artefacts_and_archives_are_not_notes(self):
        roots = [self.root]
        self.assertTrue(is_note(f"{self.root}/p/plans/a/PLAN.md", roots))
        for rel in ("p/plans/a/history/PLAN.prev.md", "p/plans/a/files/prototype.md",
                    "p/plans/a/files/spikes/run.md", ".archive/p/a.md", "p/a.txt"):
            self.assertFalse(is_note(f"{self.root}/{rel}", roots), rel)
        self.assertFalse(is_note("/elsewhere/a.md", roots))

    def test_the_project_folder_follows_so_a_note_nothing_named_is_still_there(self):
        written, script_made = self.note("p/w.md", 9), self.note("p/deep/er/made-by-a-script.md", 1)
        self.note("p/history/old.md", 1)
        self.note("other/not-this-project.md", 1)
        write_lines(self.transcript, [claude_call("Write", file_path=written)])
        self.assertEqual(self.listed("p"), [("written", written), ("project", script_made)])

    def test_a_note_outside_the_project_folder_is_still_the_sessions(self):
        elsewhere = self.note("topic-slug/plan.md")
        write_lines(self.transcript, [claude_call("Write", file_path=elsewhere)])
        self.assertEqual(self.listed("nixos"), [("written", elsewhere)])

    def test_two_notes_of_one_name_read_apart(self):
        self.assertEqual(labels(["/r/pi/plans/x/PLAN.md", "/r/wt/plans/x/PLAN.md", "/r/a/b.md"]),
                         ["pi/plans/x/PLAN.md", "wt/plans/x/PLAN.md", "a/b.md"])


class ReadTest(NotesCase):
    def test_a_note_reads_and_an_unmoved_one_says_so(self):
        path = self.note("p/a.md", text="# hi\n")
        found = self.notes.read(path)
        self.assertEqual((found["text"], found["cut"]), ("# hi\n", False))
        self.assertEqual(self.notes.read(path, found["at"]), {"path": path, "at": found["at"], "unchanged": True})

    def test_nothing_but_a_note_can_be_read(self):
        secret = self.tmp / "secret.md"
        secret.write_text("secret")
        self.note("p/a.md")
        (self.root / "p" / "link.md").symlink_to(secret)
        (self.root / "p" / "key").write_text("secret")
        for path in (str(secret), f"{self.root}/p/key", f"{self.root}/p/link.md", f"{self.root}/../secret.md", f"{self.root}/p/missing.md"):
            self.assertIsNone(self.notes.read(path), path)

    def test_a_note_read_through_the_checkout_link_is_the_same_note(self):
        path = self.note("p/a.md", text="# through the link\n")
        checkout = self.tmp / "checkout"
        (checkout / ".agents").mkdir(parents=True)
        (checkout / ".agents" / "store").symlink_to(self.root)
        linked = str(checkout / ".agents" / "store" / "p" / "a.md")
        self.assertEqual(self.notes.read(linked)["text"], "# through the link\n")
        self.assertEqual(self.notes.project_of(linked), "p")

    def test_a_link_out_of_the_store_is_still_refused(self):
        secret = self.tmp / "outside.md"
        secret.write_text("secret")
        checkout = self.tmp / "checkout"
        (checkout / ".agents").mkdir(parents=True)
        (checkout / ".agents" / "store").symlink_to(self.root)
        (self.root / "p").mkdir(parents=True)
        (self.root / "p" / "escape.md").symlink_to(secret)
        self.assertIsNone(self.notes.read(str(checkout / ".agents" / "store" / "p" / "escape.md")))

    def test_a_huge_note_is_cut_and_says_so(self):
        found = self.notes.read(self.note("p/big.md", text="x" * (NOTE_MAX + 5)))
        self.assertEqual((len(found["text"]), found["cut"]), (NOTE_MAX, True))

    def test_text_that_could_disguise_itself_shows_as_a_mark(self):
        self.assertEqual(self.notes.read(self.note("p/a.md", text="a‮b\x1b[2J"))["text"], "a�b�[2J")


class RenderTest(unittest.TestCase):
    PATH = "/home/me/.local/share/agents/store/p/plans/a/PLAN.md"

    def html(self, text):
        return render(text, self.PATH)

    def test_nothing_in_a_note_can_make_qt_reach_out(self):
        for text in ("![pixel](https://evil.example/p.png)", '<img src="https://evil.example/p.png">',
                     '![x](https://evil.example/p.png "t")', '<a href="https://evil.example"><img src=x></a>'):
            self.assertNotIn("<img", self.html(text), text)
        self.assertIn("pixel", self.html("![pixel](https://evil.example/p.png)"))

    def test_raw_html_stays_text(self):
        shown = self.html("<script>alert(1)</script>\n\nand <b>this</b>")
        self.assertNotIn("<script", shown)
        self.assertNotIn("<b>", shown)
        self.assertIn("&lt;b&gt;this&lt;/b&gt;", shown)

    def test_a_link_lives_only_if_it_goes_to_https_or_another_note(self):
        self.assertIn('<a href="https://example.org/x">', self.html("[a](https://example.org/x)"))
        for text in ("[a](http://example.org)", "[a](javascript:alert(1))", "[a](file:///etc/passwd)", "[a](note:/etc/passwd)", "[a](x.txt)"):
            self.assertNotIn("<a ", self.html(text), text)
        self.assertIn("<p>a</p>", self.html("[a](http://example.org)"))

    def test_a_relative_link_to_markdown_opens_that_note(self):
        self.assertIn('href="note:/home/me/.local/share/agents/store/p/plans/b/PLAN.md"', self.html("[b](../b/PLAN.md#top)"))
        self.assertIn('href="note:/home/me/.local/share/agents/store/p/plans/a/my report.md"', self.html("[r](my%20report.md)"))

    def test_a_notes_path_in_a_code_span_opens_it(self):
        shown = self.html("See `~/.local/share/agents/store/p/x y.md` and `/home/me/.local/share/agents/store/q/z.md`, not `/etc/a.md`.")
        self.assertIn('href="note:/home/me/.local/share/agents/store/p/x y.md"', shown)
        self.assertIn('href="note:/home/me/.local/share/agents/store/q/z.md"', shown)
        self.assertEqual(shown.count("<a "), 2)

    def test_code_keeps_its_lines_and_tables_stay_tables(self):
        shown = self.html("```\n  a <b>\n  c\n```\n\n| x | y |\n|---|---|\n| 1 | 2 |\n")
        self.assertIn("  a &lt;b&gt;\n  c</pre>", shown)
        self.assertIn('class="data"', shown)
        self.assertIn("<td>2</td>", shown)


class ProtocolCase(unittest.TestCase):
    def daemon(self, **extra):
        tmp = Path(tempfile.mkdtemp(prefix="agent-hub-notes-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        root = tmp / "agents"
        root.mkdir()
        hub = Hub(extra={"notes": [str(root)], **extra})
        self.addCleanup(hub.stop)
        return hub, root

    @staticmethod
    def open_bar(hub):
        client = hub.connect()
        client.send(op="subscribe", bar=True)
        client.wait(lambda m: m["type"] == "state")
        return client

    @staticmethod
    def ask(client, op, request=1, **fields):
        client.send(op=op, request=request, **fields)
        return client.wait(lambda m: m["type"] == "reply" and m["request"] == request)

    @staticmethod
    def claude(hub, sid, entries):
        """A Claude session whose transcript holds `entries`, reported the way its hook does."""
        proc = hub.process()
        hub.write_session(proc.pid, sid, status="idle")
        transcript = hub.write_transcript(sid, entries)
        hub.command("hook", stdin=json.dumps({"hook_event_name": "SessionStart", "session_id": sid, "transcript_path": str(transcript)}))
        return transcript


class ReaderOpsTest(ProtocolCase):
    def setUp(self):
        self.hub, self.root = self.daemon()
        self.sid = str(uuid.uuid4())
        (self.root / "p").mkdir()
        self.plan = self.root / "p" / "PLAN.md"
        self.plan.write_text("# The plan\n\n![x](https://evil.example/x.png)\n")

    def test_a_row_says_what_its_session_wrote_and_its_notes_list(self):
        bar = self.open_bar(self.hub)
        self.claude(self.hub, self.sid, [claude_call("Write", file_path=str(self.plan))])
        state = bar.wait(has_session(self.sid, lambda s: s.get("notes") == 1))
        self.assertEqual(session(state, self.sid)["note"]["name"], "p/PLAN.md")
        listed = self.ask(bar, "notes", session=self.sid)["notes"]
        self.assertEqual([(n["group"], n["path"]) for n in listed], [("written", str(self.plan))])

    def test_a_turns_end_finds_what_it_wrote_and_the_row_calls_it_new(self):
        bar = self.open_bar(self.hub)
        transcript = self.claude(self.hub, self.sid, [])
        self.hub.command("hook", stdin=json.dumps({"hook_event_name": "UserPromptSubmit", "session_id": self.sid,
                                                   "transcript_path": str(transcript), "prompt": "plan it"}))
        os.utime(self.plan)
        write_lines(transcript, [claude_call("Write", file_path=str(self.plan))], "a")
        self.hub.command("hook", stdin=json.dumps({"hook_event_name": "Stop", "session_id": self.sid, "transcript_path": str(transcript),
                                                   "last_assistant_message": "Wrote it."}))
        state = bar.wait(has_session(self.sid, lambda s: "note" in s))
        self.assertTrue(session(state, self.sid)["note"]["new"])

    def test_a_note_comes_to_the_bar_as_safe_rich_text_and_then_as_unchanged(self):
        bar = self.open_bar(self.hub)
        note = self.ask(bar, "note", path=str(self.plan))["note"]
        self.assertIn("The plan", note["html"])
        self.assertNotIn("<img", note["html"])
        self.assertNotIn("text", note)
        again = self.ask(bar, "note", request=2, path=str(self.plan), at=note["at"])["note"]
        self.assertTrue(again["unchanged"])

    def test_the_socket_reads_nothing_but_notes(self):
        bar = self.open_bar(self.hub)
        self.assertNotIn("note", self.ask(bar, "note", path=str(self.hub.tmp / "config.json")))

    def test_a_note_alone_lists_its_own_project(self):
        bar = self.open_bar(self.hub)
        listed = self.ask(bar, "notes", path=str(self.plan))["notes"]
        self.assertEqual([(n["group"], n["path"]) for n in listed], [("project", str(self.plan))])

    def test_show_reaches_bars_and_says_so_and_nothing_else_counts_as_one(self):
        self.hub.subscribe()
        with self.assertRaises(subprocess.CalledProcessError):
            self.hub.command("show", str(self.plan))
        bar = self.open_bar(self.hub)
        self.hub.command("show", str(self.plan), "--session-id", self.sid)
        shown = bar.wait(lambda m: m["type"] == "show")
        self.assertEqual((shown["session"], shown["path"], shown["toggle"]), (self.sid, str(self.plan), False))

    def test_show_leaves_a_file_it_wont_serve_to_whoever_can_open_it(self):
        self.open_bar(self.hub)
        with self.assertRaises(subprocess.CalledProcessError):
            self.hub.command("show", str(self.plan.parent / "history" / "PLAN.prev.md"))

    def test_show_with_no_session_means_the_focused_windows(self):
        proc = self.hub.process()
        bar = self.open_bar(self.hub)
        self.hub.niri({"WindowsChanged": {"windows": [{"id": 7, "pid": proc.pid, "is_focused": True}]}})
        self.hub.write_session(proc.pid, self.sid, status="idle")
        bar.wait(has_session(self.sid, lambda s: s["window"] == 7))
        self.hub.command("show", "--toggle")
        shown = bar.wait(lambda m: m["type"] == "show")
        self.assertEqual((shown["session"], shown["toggle"]), (self.sid, True))

    def test_the_cli_lists_a_sessions_notes(self):
        self.claude(self.hub, self.sid, [claude_call("Read", file_path=str(self.plan))])
        out = self.hub.command("notes", "--session-id", self.sid).stdout
        self.assertEqual(out, f"read\t{self.plan}\n")

    def test_the_status_line_gets_the_path_of_the_note_it_wrote(self):
        bar = self.open_bar(self.hub)
        self.claude(self.hub, self.sid, [claude_call("Write", file_path=str(self.plan))])
        bar.wait(has_session(self.sid, lambda s: "note" in s))
        self.assertEqual(self.hub.command("status", "--session-id", self.sid).stdout.rstrip("\n").split("\t")[-1], str(self.plan))

    def test_editing_opens_the_configured_editor_and_only_on_a_note(self):
        for editor, argv in (("zed", ["zed"]), ("vscode", ["code", "--reuse-window"])):
            with self.subTest(editor=editor):
                tmp = self.hub.tmp / "bin" / editor
                tmp.mkdir(parents=True)
                command = tmp / ("code" if editor == "vscode" else editor)
                command.write_text("")
                command.chmod(0o755)
                hub, root = self.daemon(appPath=[str(tmp)], editor=editor)
                note = root / "a.md"
                note.write_text("x")
                bar = self.open_bar(hub)
                for value in (str(hub.tmp / "config.json"), str(note)):
                    bar.send(op="run", session="", kind="note", value=value)
                spawned = Path(str(hub.focus_log) + ".spawn")
                self.assertEqual(logged(spawned), [argv + [str(note)]])


class RemoteNotesTest(ProtocolCase):
    """A note on another host, through the real `attach` with its forced `--control`."""

    def setUp(self):
        self.far, self.far_root = self.daemon()
        self.tmp = Path(tempfile.mkdtemp(prefix="agent-hub-link-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        (self.tmp / "far").symlink_to(self.far.socket.parent.parent)
        ssh = self.tmp / "ssh"
        ssh.write_text(FAKE_SSH.format(python=sys.executable, runtimes=str(self.tmp), log=str(self.tmp / "ssh.log"), package=str(PACKAGE)))
        ssh.chmod(0o755)
        self.near = Hub(extra={"remotes": ["far"], "ssh": str(ssh), "sshConfig": "/dev/null"})
        self.addCleanup(self.near.stop)
        self.sid = str(uuid.uuid4())
        self.rid = f"far:{self.sid}"
        self.note = self.far_root / "p" / "PLAN.md"
        self.note.parent.mkdir()
        self.note.write_text("# Far plan\n\n![x](https://evil.example/x.png)\n")
        self.bar = self.open_bar(self.near)
        self.claude(self.far, self.sid, [claude_call("Write", file_path=str(self.note))])
        self.row = session(self.bar.wait(has_session(self.rid, lambda s: "note" in s)), self.rid)

    def test_the_row_and_its_list_come_from_the_far_host(self):
        self.assertEqual(self.row["note"]["path"], str(self.note))
        listed = self.ask(self.bar, "notes", session=self.rid)["notes"]
        self.assertEqual([(n["group"], n["path"]) for n in listed], [("written", str(self.note))])

    def test_the_viewer_renders_what_the_far_host_sends(self):
        note = self.ask(self.bar, "note", path=str(self.note), session=self.rid)["note"]
        self.assertIn("Far plan", note["html"])
        self.assertNotIn("<img", note["html"])
        self.assertTrue(self.ask(self.bar, "note", request=2, path=str(self.note), session=self.rid, at=note["at"])["note"]["unchanged"])

    def test_the_far_host_reads_nothing_but_its_own_notes(self):
        self.assertNotIn("note", self.ask(self.bar, "note", path=str(self.far.tmp / "config.json"), session=self.rid))


class AttachFilterNotesTest(unittest.TestCase):
    def test_a_link_key_without_control_can_ask_for_no_notes(self):
        self.assertIsNone(links.attach_filter(b'{"op":"notes","session":"s","request":1}', False))
        self.assertIsNone(links.attach_filter(b'{"op":"note","path":"/a.md","request":1}', False))

    def test_control_adds_reading_notes_rebuilt_from_their_fields(self):
        self.assertEqual(links.attach_filter(b'{"op":"notes","session":"s","request":1,"path":"/evil","evil":1}', True),
                         {"op": "notes", "session": "s", "request": 1})
        self.assertEqual(links.attach_filter(b'{"op":"note","path":"/a.md","request":2,"at":3,"evil":1}', True),
                         {"op": "note", "path": "/a.md", "request": 2, "at": 3})
        self.assertIsNone(links.attach_filter(b'{"op":"show","path":"/a.md"}', True))

    def test_a_subscribe_through_attach_can_never_be_a_bar(self):
        self.assertNotIn("bar", links.attach_filter(b'{"op":"subscribe","version":3,"bar":true}', True))

    def test_what_another_host_lists_is_cleaned(self):
        cleaned = links.clean_notes([{"path": "/a.md", "name": "a\x1b[2J", "group": "evil", "at": "x"}, {"path": "relative.md"}, {"path": "/b\n.md"}, 7])
        self.assertEqual(cleaned, [{"path": "/a.md", "name": "a [2J", "group": "project", "at": 0}])
        self.assertIsNone(links.clean_notes("no"))


if __name__ == "__main__":
    unittest.main()
