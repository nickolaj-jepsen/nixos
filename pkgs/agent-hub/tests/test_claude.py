"""Reading Claude Code: what a command line shows."""

import unittest

from agent_hub import claude


class CommandLineTest(unittest.TestCase):
    def test_a_leading_cd_says_nothing_of_what_the_command_is(self):
        place = "/home/me/worktrees/some-repo/a-long-branch-name-that-fills-the-line"
        for command in (f"cd {place} && just build", f"cd {place}; just build", f'cd "{place}" && cd sub && just build'):
            self.assertEqual(claude.command_line(command), "just build")

    def test_a_cd_with_nothing_after_it_on_the_line_stays(self):
        self.assertEqual(claude.command_line("cd /repo &&\njust build"), "cd /repo &&")
        self.assertEqual(claude.command_line("cd /repo"), "cd /repo")
