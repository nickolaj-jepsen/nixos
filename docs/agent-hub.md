# agent-hub

A desktop overview of every live pi and Claude Code session, and a quick way
to the ones that want you. The DMS bar shows a dot per session that isn't idle.

- `Mod+B` opens the popout with the longest-waiting session selected; `Enter`
  (or a click) focuses its window, `x` dismisses a finished one, `j`/`k` move
  and `g`/`G` jump to the ends. Idle sessions are listed too, dimmed, last.
- `Mod+Shift+B` (`agent-hub focus-next`) jumps straight to the next session that
  wants you, cycling on repeat.
- `Mod+Ctrl+B` (`agent-hub toggle`) dismisses the finished turn of the session
  you're looking at, or brings back the one you dismissed.
- A toast fires when a session you aren't looking at comes to want you;
  clicking it focuses the session.

The bar never answers anything: you answer in the agent's own terminal.

## States

In the order the popout lists them. The first four want you; looking at a
session never clears one, only its next turn or `x` does.

- **asking**: a dialog is open that wants an answer. Its entry in the session
  registry (`~/.claude/sessions`) says `status: "waiting"`. Claude Code writes
  that itself, with a `waitingFor` naming the dialog (`permission prompt`,
  `input needed`), and its `PermissionRequest` hook (`agent-hub hook`, set in
  `modules/programs/claude-code/default.nix`) sends the daemon a one-line label
  of the call. pi's `claude-peers` extension writes it, with the label, while
  pi-permission-system has a dialog open. Claude also says `waiting` for modals
  that only show something (the history view, `/config`): those carry
  `waitingFor: "dialog open"` and leave the session in the state it was in, so
  closing one neither re-announces its last turn nor forgets a dismissal.
- **needs reply**, **failed**, **done**: how the last turn ended. pi's sidecar
  already judges every turn, and `claude-peers` writes its verdict into the
  registry (`turnState`, `ask`). Claude Code's `Stop` hook hands the daemon the
  transcript instead: a question in the turn's last words is an ask, and a long
  turn that looks done, or one that left background jobs running, goes to
  `claude -p --model haiku` as the session's own profile (`CLAUDE_CONFIG_DIR`),
  so a `claude-work` transcript stays on the work account.
- **working**: busy, or a Claude Code turn that ended only to wait for its own
  background jobs. A dev server it left running for you doesn't count.
- **idle**: fresh, or dismissed.

Finished turns and dismissals live in `~/.local/state/agent-hub/state.json`, so
a daemon restart keeps them.

## Pieces

- `pkgs/agent-hub/agent_hub.py`, the daemon (`agent-hub daemon`, a user
  service). Its module docstring is the protocol. Window focus comes from
  niri's event stream; the order of its `state` message is the one the popout
  lists and `focus-next` walks.
- `modules/desktop/dms/agent-hub/`, the bar plugin. One socket subscription
  lives in its daemon component, which every bar's widget shares.
- `modules/programs/pi/extensions/parent/claude-peers.ts`, pi's registry entry.

Claude Code can park a conversation in a background job under its daemon (the
front's entry gets `parkedJobId`); the daemon shows the job's entry in the
front's place, under the front's window.

## Limits

- Only top-level sessions register. A Claude Code started from inside another
  one (`CLAUDE_CODE_CHILD_SESSION` set) and headless runs never show up.
- `claude-work` shares the personal profile's registry through the
  `~/.claude-work/sessions` symlink home-manager owns. A hand-made link there
  blocks the first switch; remove it first.

## Working on it

- `agent-hub demo` puts fake sessions in every state on the bar until Ctrl-C.
- `journalctl --user -u agent-hub` shows the daemon's log.
- The protocol tests run in every `nix build .#agent-hub`, or with
  `python3 -m unittest tests/test_hub.py` from `pkgs/agent-hub`.
