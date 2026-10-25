# agent-hub

A desktop overview of every live pi and Claude Code session, and a quick way
to the ones stuck on you. The DMS bar shows a dot per session that needs you,
has finished a turn you haven't looked at, or is working.

- `Mod+B` opens the popout with the longest-waiting session selected; `Enter`
  (or a click) focuses its window, `j`/`k` move.
- `Mod+Shift+B` (`agent-hub focus-next`) jumps straight to the next session that
  wants you, cycling on repeat.
- A toast fires when a session you aren't looking at starts waiting or ends its
  turn; clicking it focuses the session.

The bar never answers anything: you answer in the agent's own terminal.

## Where "needs you" comes from

The session registry alone (`~/.claude/sessions`). A session needs you while
its entry says `status: "waiting"`:

- Claude Code writes that itself for any dialog, with a generic `waitingFor`
  ("permission prompt", "input needed", ...). Its `PermissionRequest` hook
  (`agent-hub hook`, set in `modules/programs/claude-code/default.nix`) sends
  the daemon a one-line label of the call; the daemon shows it until the
  session's status moves on.
- pi's `claude-peers` extension writes it, with the label, while
  pi-permission-system has a dialog open.

## Pieces

- `pkgs/agent-hub/agent_hub.py`, the daemon (`agent-hub daemon`, a user
  service). Its module docstring is the protocol. Window focus comes from
  niri's event stream; the order of its `state` message is the one the popout
  lists and `focus-next` walks.
- `modules/desktop/dms/agent-hub/`, the bar plugin. One socket subscription
  lives in its daemon component, which every bar's widget shares.
- `modules/programs/pi/extensions/parent/claude-peers.ts`, pi's registry entry.

## Limits

- Only top-level sessions register. A Claude Code started from inside another
  one (`CLAUDE_CODE_CHILD_SESSION` set) and headless runs never show up.
- `claude-work` shares the personal profile's registry through the
  `~/.claude-work/sessions` symlink home-manager owns. A hand-made link there
  blocks the first switch; remove it first.

## Working on it

- `agent-hub demo` puts fake sessions in every state on the bar until Ctrl-C.
- `journalctl --user -u agent-hub` shows the daemon's log.
- The protocol tests run with `nix build .#checks.x86_64-linux.agent-hub-tests`,
  or with `python3 -m unittest tests/test_hub.py` from `pkgs/agent-hub`.
