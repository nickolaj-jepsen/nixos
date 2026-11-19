# agent-hub

A daemon that knows every live pi and Claude Code session on its host and whether it wants
you. It calls no model: every state is the agent's own word, through its hooks or its registry
entry, and so is every name. Nothing flows from the hub back into an agent.

A desktop bar (the DMS plugin in a system config) is its only reader. Elsewhere it runs
headless, polling the registry instead of watching it, to serve viewers.

- Socket: `$XDG_RUNTIME_DIR/agent-hub/hub.sock`, or `~/.local/state/agent-hub/hub.sock` where
  there is no runtime dir.
- Config: `~/.config/agent-hub/config.json`.
- It keeps nothing on disk. After a restart it rebuilds from the registry alone: a busy
  session is `working`, the rest `idle`, and nothing pulses. A turn that ends while the daemon
  is down is never announced. `state.json` and `log.jsonl` from older versions are ignored and
  can be deleted.

## States

`asking` (a dialog waits on you), `failed`, `done`, `working` and `idle`, in that order; the
first three want you.

- A turn's ending is `done` unless the agent failed it. The closing words are not read to
  guess whether they ask something.
- A turn that stopped only to wait on its own background work stays `working`: agent work in
  flight always reports back, and a shell job counts only when the closing words say they wait
  on it (`WAITS` in `model.py`), since it can as well be a server left running.
- A turn woken by another session's message (a peer) leaves the standing ending and its age
  alone; only a failure reaches the row.
- Claude marks every open modal `waiting`; one named `dialog open` only shows something and
  changes nothing.
- A working row says it is working and for how long. There is no percentage and no `stuck`
  state: a long build looks exactly like a hang.
- An asking row says who and what kind of dialog (`waitingFor`), and nothing of the call.

## Where a state comes from

- **Claude Code**: its registry entry (`~/.claude/sessions/*.json`) says `busy`, `idle` or
  `waiting` with `waitingFor`, and three hooks, all fire-and-forget (`agent-hub hook`), say the
  rest. They never print and never wait for the hub.
  - `UserPromptSubmit` starts a turn, and says when a peer's message woke it
    (`<cross-session-message from=` at the head of the prompt).
  - `Stop` ends it, with the closing words and the background tasks still out.
  - `StopFailure` ends it as `failed`, with the agent's own error.
  - The registry can say `busy` before the hook does, so a turn starts only after
    `REGISTRY_GRACE_MS`, and `idle` with a turn open ends it as interrupted (Esc fires no
    Stop). A Stop that lands after that still counts.
- **pi**: its registry entry only, written by the pi extension in a system config, with no
  socket connection. Besides `status`, `waitingFor`, `name` and `nameSource` it carries
  `hubFailed` (the error, written with the move to `idle`), `hubPeer` (a peer woke this turn),
  `hubHidden` and `tmux`. A busy-to-idle move is `done` unless `hubFailed` is set.
- Claude Code can park a conversation in a background job under its daemon; the front's entry
  gets `parkedJobId`, and the job's entry shows in the front's place, under the front's window.
- A session's window is the compositor's window whose process is its pid or an ancestor.

## Names and repositories

- A row is named by `/rename` or `/name` (the registry's `nameSource: user`), else Claude's
  `ai-title` read from the transcript, else the registry's name, else the folder.
- Only `custom-title` and `ai-title` entries are read from the transcript, incrementally, on
  the hooks and when the popout opens (`TitleTail`). It is the only transcript read left.
- The repository name is one `git rev-parse --git-common-dir` when a session is first seen,
  the same from any worktree, or the folder's own name outside git.

## Links

There is no server. Each host's hub owns its own sessions, and a viewer pipes the rows in with
`ssh <host> agent-hub attach`, over a Unix socket on the far end, with no TCP port of its own.
The link is read-only.

- `attach` passes `subscribe` and nothing else (`attach_filter`), so a link key can change
  nothing on the far host. A subscribe through it gets that host's own sessions only, so hubs
  listing each other never echo rows around.
- Remote rows are untrusted (`clean_row`): the viewer stamps the host, ids must be UUIDs,
  control characters go, and every command is built locally.
- `attach` beats every 20 s, and a link silent for a minute reconnects. There is no version
  check: hubs on different builds may show `needs a switch` until both are switched.
- `x` and `Enter` on a remote row hide its current ending at this viewer, in memory; the far
  host is told nothing. `Enter` opens its tmux pane over ssh in a new terminal, or its Remote
  Control page.

## Limits

- `AGENT_HUB_HIDDEN=1` in a session's environment hides it in every state, with no way to
  reveal it. Set it for anything an agent starts to test with. It is the only opt-out.
- Only top-level sessions register. A Claude Code started from inside another one
  (`CLAUDE_CODE_CHILD_SESSION` set) and headless runs never show up.
- Background sessions `claude agents` lists with no pid stay out of the hub.

## Working on it

- `nix build .#agent-hub --rebuild -L` runs the protocol tests; a cached build runs none.
- `agent-hub demo` puts one fake session in each state on the bar until Ctrl-C.
- `journalctl --user -u agent-hub` is the daemon's log, `~/Library/Logs/agent-hub.log` on a
  Mac. It has one line per state change: the session and its old and new state, with `read` or
  `interrupted` for a turn gone straight to idle. Never the words themselves.
