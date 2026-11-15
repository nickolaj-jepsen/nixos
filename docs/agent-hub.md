# agent-hub

A daemon that knows every live pi and Claude Code session on its host and whether it wants
you. It calls no model: every state is the agent's own word, through its hooks or its
registry entry, and so is every name.

It does one job: the DMS bar shows which sessions want you and gets you to them. Anything
else (answering a prompt, reading what a session said, resuming one) is what the agent's own
terminal is for. Nothing flows from the hub back into an agent.

- On a niri desktop the bar shows a dot per session that wants you and a ring per working
  one.
- Elsewhere (a server, the Mac) the hub runs headless: no windows, and it polls the
  registry instead of watching it. It still runs, to serve viewers.
- Its socket is `$XDG_RUNTIME_DIR/agent-hub/hub.sock`, or
  `~/.local/state/agent-hub/hub.sock` where there is no runtime dir.
- It keeps nothing on disk. After a restart it rebuilds from the registry alone: a busy
  session is `working`, the rest `idle`, and nothing pulses. A turn that ends while the
  daemon is down is never announced. `~/.local/state/agent-hub/{state.json,log.jsonl}` from
  older versions are ignored and can be deleted.

## States

`asking` (a dialog waits on you), `failed`, `done`, `working` and `idle`, in the order the
bar lists them; the first three want you.

- A turn's ending is `done` unless the agent failed it. The hub doesn't read the closing
  words to guess whether they ask something.
- A turn that stopped only to wait on its own background work stays `working`: agent work
  in flight always reports back, and a shell job counts only when the closing words say they
  wait on it (`WAITS` in `model.py`), since it can as well be a server left running.
- A turn woken by another session's message (a peer) is not yours. It leaves the standing
  ending and its age alone, and only a failure reaches the row.
- Claude marks every open modal `waiting`; one named `dialog open` only shows something
  (the history view, `/config`) and changes nothing.
- A working row says it is working and for how long. There is no percentage and no `stuck`
  state: a long build looks exactly like a hang, so the bar shows the time.
- An asking row says who and what kind of dialog (`waitingFor`), and nothing of the call.
  Answer it in the agent's terminal.

## The popout

One list, no pane. A row shows the session's name, its repository, its state and its age.

- Click or `Enter` focuses the session's window. Focusing a `done` session's window reads
  it, so it goes idle.
- `x` dismisses a finished turn, or hides an open prompt until the next one. `u` brings
  back the last dismissal, until that session starts a new turn.
- `j`/`k` move, `g`/`G` jump to the ends.
- `Mod+B` opens the popout with the first row selected. `Mod+Shift+B`
  (`agent-hub focus-next`) jumps to the next session that wants you, cycling on repeat.
  `Mod+Ctrl+B` (`agent-hub toggle`) dismisses the finished turn of the session you're looking
  at, or brings back the one you dismissed. All three are niri binds
  (`modules/desktop/niri/binds.nix`); Hyprland has none.
- Dismissals and the undo stack live in the daemon's memory.
- The order of the `state` message is the one the popout lists and `focus-next` walks.

## Alerts

The bar shows no popups. Terminal bells stay, as they are the agent's own.

- A session's dot bursts when it comes to want you, then breathes until the popout opens or
  you focus its window. A `done` bursts once.
- A permission prompt also peeks out of the pill for 4 s, saying who, and a click on it goes
  to that session. A vertical bar has no room for the peek.
- Nothing pulses when you are looking at that window, for a dialog answered within a second,
  or at first sight of a host (the hub starting, a link coming up).
- The hub computes the pulse (`Alerts` in `agent_hub/model.py`). What `u` brings back
  doesn't pulse.

## Where each state comes from

- Claude Code: its registry entry (`~/.claude/sessions/*.json`) says `busy`, `idle` or
  `waiting` with `waitingFor`, and three hooks, all fire-and-forget (`agent-hub hook`),
  say the rest. They never print anything and never wait for the hub.
  - `UserPromptSubmit` starts a turn, and says when a peer's message woke it
    (`<cross-session-message from=` at the head of the prompt).
  - `Stop` ends it, with the closing words and the background tasks still out.
  - `StopFailure` ends it as `failed`, with the agent's own error.
  - The registry can say `busy` before the hook does, so it starts a turn only after
    `REGISTRY_GRACE_MS`, and `idle` with a turn open ends it as interrupted (Esc fires no
    Stop). A Stop that lands after that still counts.
- pi: its registry entry only, written by
  `modules/programs/pi/extensions/parent/claude-peers.ts`, with no socket connection.
  Beside `status`, `waitingFor`, `name` and `nameSource` it carries `hubFailed` (the error,
  written with the move to `idle`), `hubPeer` (a peer woke this turn), `hubHidden` and
  `tmux`. A busy-to-idle move is `done` unless `hubFailed` is set (`Hub._observe_pi`).
- Claude Code can park a conversation in a background job under its daemon; the front's
  entry gets `parkedJobId`. The daemon then shows the job's entry in the front's place, under
  the front's window (`registry.py`).
- A session's window is the compositor's window whose process is its pid or an ancestor
  (`desktop.py`, niri's event stream).

## Names and repositories

- A row is named by `/rename` or `/name` (the registry's `nameSource: user`), else Claude's
  `ai-title` read from the transcript, else the registry's name, else the folder. pi's own
  title side call (`parent/identity.ts`) stays.
- The transcript's path comes from the hooks, and it is read only for `custom-title` and
  `ai-title` entries, incrementally, on the hooks and when the popout opens (`TitleTail` in
  `claude.py`). It is the only transcript read left.
- The repository name is one `git rev-parse --git-common-dir` when a session is first seen,
  the same from any worktree (`repo.py`), or the folder's own name outside git. There is no
  branch, changed-files or pull request lookup.

## Other hosts

There is no server. Each host's hub owns its own sessions, and a viewer pipes the rows in
with `ssh <host> agent-hub attach`, over a Unix socket on the far end, with no TCP port of
its own. The link is read-only.

- Host cards list `fireproof.dev.agent-hub.remotes`, the hosts this one shows, and
  `viewers`, the hosts that may attach here.
- A remote is named as `ssh <host>` knows it. Its address, user and jump come from the login
  config, and its entry in `remotes` overrides them (`ProxyJump = "none"` where a host is on
  the same LAN).
- A link uses the viewer's own key, `secrets/hosts/<viewer>/agent-hub-link.age`, and its own
  `~/.config/agent-hub/ssh_config`. The login config's `*` would multiplex it over a full
  login.
- On the far end that key is `restrict` with a forced `agent-hub attach`, so it can do
  nothing else. A jump host also opens the hops in `linkJumps`.
- A jump host outside this repo can't take the link key, so a remote behind one shows only
  on viewers that reach it directly. `dev.ao` shows on `work` for this reason: from anywhere
  else it sits behind `bastion.ao`.
- A `class = "home"` or darwin host has no `users.users`, so home-manager's activation
  writes the link keys into `~/.ssh/authorized_keys`. It replaces only lines whose comment
  starts `agent-hub-link-`, so the logins already in that file stay.
- A `class = "home"` host needs `loginctl enable-linger` once, by hand. Without it the hub
  stops at your last logout and starts again at your next login, and the viewer says
  `no hub`. On a Mac the hub is a launchd agent, which runs while you are logged in.
- `attach` passes `subscribe` and nothing else (`attach_filter` in `agent_hub/links.py`), so
  a link key can change nothing on the far host. A subscribe through it gets that host's own
  sessions only, so hubs listing each other never echo rows around.
- Remote rows are untrusted (`clean_row`). The viewer stamps the host, ids must be UUIDs,
  control characters go, and every command is built locally.
- `attach` beats every 20 s, and a link silent for a minute reconnects. The popout says why a
  link is down: auth failed, timeout, no hub, host down or needs a switch. There is no
  version check: hubs on different builds may show `needs a switch` until both are switched.
- `x` and `Enter` on a remote row hide its current ending at this viewer, in memory; the far
  host is told nothing, and a newer ending shows again. `u` brings it back.
- `Enter` on a remote row opens its tmux pane over ssh in a new terminal, or its Remote
  Control page. With neither, nothing happens.

## Sessions that stay off the bar

`AGENT_HUB_HIDDEN=1` in a session's environment hides it in every state, with no way to
reveal it, and the popout counts how many are hidden. Set it for anything an agent starts to
test with; both skills' `tui.sh` do. It is the only opt-out.

- pi writes it to its registry entry (`hubHidden`).
- For Claude, the hub reads `/proc/<pid>/environ` when it first sees the session. Where there
  is no `/proc` (macOS) the hooks carry it, so an idle row before the first prompt shows.
- A hidden session gets no pulse and no `focus-next`.

## Limits

- Only top-level sessions register. A Claude Code started from inside another one
  (`CLAUDE_CODE_CHILD_SESSION` set) and headless runs never show up.
- Background sessions `claude agents` lists with no pid stay out of the hub.
- `claude-work` shares the personal profile's registry through the
  `~/.claude-work/sessions` symlink home-manager owns. A hand-made link there blocks the
  first switch; remove it first.

## How it works

- The daemon is `agent-hub daemon` (`pkgs/agent-hub/agent_hub/`), a user service.
  - `protocol` defines every message and the row.
  - `model` holds the session rules and how a turn ends, pure and tested as data.
  - `hub` is the shell that wires them to the socket, the registry and the compositor.
  - `registry`, `desktop`, `links`, `claude` (the title) and `repo` do one thing each.
- The bar plugin is `modules/desktop/dms/agent-hub/`. One socket subscription lives in its
  daemon component (`HubDaemon.qml`), which every bar's widget shares. It sends `subscribe`,
  `focus`, `dismiss`, `undo` and `seen`.
- Config is `~/.config/agent-hub/config.json`, written by `modules/programs/agent-hub.nix`.
- Claude Code shows a pi receipt as fixed text for its status and ignores `reason`, so pick
  the status by what that text says (`ReceiptStatus` in `claude-peers/protocol.ts`).

## Working on it

- A switch doesn't reload the bar plugin: run `systemctl --user restart dms` to see a QML
  change.
- `agent-hub demo` puts one fake session in each state on the bar until Ctrl-C.
- `journalctl --user -u agent-hub` shows the daemon's log; on the Mac it is
  `~/Library/Logs/agent-hub.log`. It has one line per state change: the session and its old
  and new state, with `read` or `interrupted` for a turn gone straight to idle. Never the
  words themselves, as homelab's journal ships to Grafana Cloud.
- The protocol tests run in every `nix build .#agent-hub`, and `--rebuild -L` runs them
  again.
