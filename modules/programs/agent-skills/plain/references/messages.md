# Messages to people

Email, Slack, an issue or a comment. The reader is busy and deciding whether to act.

- The ask goes first, with its deadline if it has one. Then only the context needed to act on it.
- One ask per message. A second topic is a second message.
- Cut what the reader already knows and what they won't care about. Ask "would they miss this line?"
- Self-contained: no "as discussed", no names or terms from your own work they haven't seen.
- Short bullets are fine for options or separate facts. Keep each one to a line, and don't nest them.
- No greeting-only openers and no closing offers to help further.
- An email subject is the summary plus the action: "Review needed by Friday: new worktree cleanup".

## Example

```text
Hi! Hope you're doing well. I've been working on the worktree tooling over the
last couple of days and made some changes to how cleanup works. Previously
sessions closed their own worktrees, but this caused some issues, so now they
stay open and get closed from outside. There's also a new `wt clean` command.
It would be great if you could take a look when you have a moment, ideally
before Friday since I'd like to land it then.

→
Could you review cc9f8fd4 before Friday? I'd like to land it then.

It changes worktree cleanup: sessions no longer close their own worktree,
and `wt clean` closes the finished ones from the main checkout.
```

The ask moved from the last sentence to the first, and the history the reader doesn't need went away.
