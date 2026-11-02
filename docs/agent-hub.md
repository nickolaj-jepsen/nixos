# agent-hub

A daemon that knows every live pi and Claude Code session on its host: what each
one is called, the step it is on, and how its last turn ended.

- Each agent's TUI shows the hub's row for its own session.
- On a niri desktop the DMS bar shows a dot per session that wants you and a ring
  per working one, and is a quick way to them.
- The bar never answers anything: you answer in the agent's own terminal.
- Elsewhere (a server, the Mac) the hub runs headless: no windows, and it polls
  the registry instead of watching it.
- Its socket is `$XDG_RUNTIME_DIR/agent-hub/hub.sock`, or
  `~/.local/state/agent-hub/hub.sock` where there is no runtime dir.

## Keys

- `Mod+B` opens the popout with the first row selected. The first session waiting
  on you is a card with its ask in full, and the rest go under Also waiting,
  Finished and Working.
  - `Enter` (or a click) focuses its window.
  - `x` dismisses a finished one, or hides an open prompt until the next prompt.
  - `u` brings back the last dismissal, until that session starts a new turn. The
    stack lives in the hub the bar talks to, in memory.
  - `w` logs its verdict as wrong, for tuning the gate.
  - `j`/`k` move, and `g`/`G` jump to the ends. The card stays where it is, and
    the selected row opens to its full reason and last turns.
  - Idle sessions and the last few that ended are folded to a line each, which
    unfolds when selected. `Enter` on an ended one resumes it in a new terminal.
- `Mod+Shift+B` (`agent-hub focus-next`) jumps straight to the next session
  that wants you, cycling on repeat.
- `Mod+Ctrl+B` (`agent-hub toggle`) dismisses the finished turn of the session
  you're looking at, or brings back the one you dismissed.

## Alerts

The bar shows no popups. Terminal bells stay, as they are the agent's own.

- A session's dot bursts when it comes to want you, then breathes until the popout
  opens or you focus its window. A `done` bursts once.
- An ask also peeks out of the pill for 4 s, saying who. A vertical bar has no room
  for the peek.
- Nothing pulses when you are looking at that window, for a dialog answered within
  a second, or on a restart for turns the hub already knew.
- The hub computes the pulse (`Alerts` in `agent_hub/model.py`) and keeps what it has
  announced in its state file. A turn that ended while the daemon was down is news.
- What `u` brings back doesn't pulse.

## Other hosts

There is no server. Each host's hub owns and judges its own sessions, and a viewer
pipes the rows in with `ssh <host> agent-hub attach`, over a Unix socket on the far
end, with no TCP port of its own.

- Host cards list `fireproof.dev.agent-hub.remotes`, the hosts this one shows, and
  `viewers`, the hosts that may attach here.
- A remote is named as `ssh <host>` knows it. Its address, user and jump come from
  the login config, and its entry in `remotes` overrides them (`ProxyJump = "none"`
  where a host is on the same LAN).
- A link uses the viewer's own key, `secrets/hosts/<viewer>/agent-hub-link.age`, and
  its own `~/.config/agent-hub/ssh_config`. The login config's `*` would multiplex it
  over a full login.
- On the far end that key is `restrict` with a forced `agent-hub attach`, so it can do
  nothing else. A jump host also opens the hops in `linkJumps`.
- `attach` passes `subscribe`, and with `--control` also `dismiss` and `undismiss`,
  each rebuilt from its allowed fields (`attach_filter` in `agent_hub/links.py`).
- A subscribe through `attach` gets that host's own sessions only, so hubs listing
  each other never echo rows around.
- Remote rows are untrusted (`clean_row`). The viewer stamps the host, ids must be
  UUIDs, control characters go, and every command or URL is built locally.
- `attach` beats every 20 s, and a link silent for a minute reconnects. The popout
  says why a link is down: auth failed, timeout, no hub, host down or needs a switch.
- `x` and `u` on a remote row name the turn, so a late one can't touch a newer ending.
- `Enter` on a remote row opens its tmux pane over ssh in a new terminal, or its
  Remote Control page. With neither, the row says there is no way from here.
- An ended session on another host resumes over ssh.

## Sessions that stay off the bar

- `AGENT_HUB_HIDDEN=1` in a session's environment hides it in every state, with no
  way to reveal it. Hooks and pi report it from their own environment. Set it for
  anything an agent starts to test with; `skills/pi-plugin-dev/scripts/tui.sh` does.
- A hidden session gets no pulse, no `focus-next`, no model reading and no place in
  another session's peers note, but keeps its own row in its own TUI.
- `agent-hub status` with no arguments lists every session and counts the hidden
  ones, since an agent could set it on purpose.
- `AGENT_HUB=off` turns the hub off for a session: its hooks do nothing and pi never
  attaches. It then works as if there were no hub.

## Naming and judging

The hub reads every session the same way, whichever agent runs it. One prompt
and one parser (`agent_hub/judge.py`) serve both agents.

- At a turn's start a model names the work (`label`), the step in flight
  (`doing`), a sentence about the session and its tags.
- At a turn's end the same prompt also asks how it ended, what it did, what it
  asks of you and the reply you would likely type.
- The model reads a digest, not the transcript: the latest requests, the files
  touched, the commands run, jobs still out, and the turn's closing words.
- A prompt that only agrees ("ok", "thanks") is not worth naming the work again.

Who runs the call differs:

- **pi** attaches to the hub for the session's life (`parent/lib/hub.ts`). The
  hub reads its session file along the current branch (`agent_hub/pi.py`) and
  asks pi to run the call, so it goes through pi's own side model and shows in
  `/cost` (`session label`, `session ask`).
- **Claude Code** reaches the hub through `agent-hub hook` (set in
  `modules/programs/claude-code/default.nix`). The hub runs `claude -p --model
haiku` as the session's own profile (`CLAUDE_CONFIG_DIR`, which `SessionStart`
  reports), so a `claude-work` transcript stays on the work account. A named
  session is renamed at most every ten minutes.

### The gate

Only a turn whose closing words hold a `?` or request words ("tell me when",
"your call") can need a reply. That rule and the model's word both live in
`agent_hub/judge.py`.

- The model reads every turn and writes its summary.
- It can only demote a candidate to `done`: an offer to deploy or switch,
  optional extras, a pointer at your next step, a rhetorical `?`.
- An offer to commit or push stays `needs-reply`, as does asking you to do
  something and report back.
- If the model fails, the candidate stays `needs-reply`.
- `failed` comes only from the agent's own error: Claude's `StopFailure`, or pi's
  error stop. The model can't call a turn failed.
- Three failures in a row, or 500 readings, and the session is not asked again.
- A name you chose (`/name` in pi, `/rename` in Claude Code) outranks the label.
  Until then pi's session name follows it, so `/resume` lists it.

### What the hub trusts

- A turn starts and ends on the agent's own word: pi's messages, Claude's
  `UserPromptSubmit` and `Stop` hooks.
- Claude's `Stop` carries the closing words and the tasks still in flight. The
  hub trusts those over the transcript, which can lag at `Stop`. The transcript
  supplies the rest of the digest, and is the fallback.
- Subagent, workflow, teammate, monitor and cloud tasks in flight mean `working`,
  with no model call. A `shell` task goes to the model, since it can't be told
  from a dev server left running. A question in the closing words beats both.
- The registry only stands in where that word never comes: a session going busy
  with no turn open starts one, and one going idle mid-turn ends it unread (Esc
  fires no `Stop`).
- A new turn cancels the reading of the last one's ending, and a reading that
  lands late is dropped. `agent_hub/model.py` holds these rules,
  `agent_hub/readings.py` the calls.

## States

In the order the popout lists them. The first four want you.

- **asking**: a dialog is open that wants an answer.
  - Its entry in the session registry (`~/.claude/sessions`) says
    `status: "waiting"`.
  - Claude Code writes that itself, with a `waitingFor` naming the dialog
    (`permission prompt`, `input needed`), and its `PermissionRequest` hook sends
    the daemon a one-line label of the call.
  - pi reports its own while pi-permission-system has a dialog open.
  - Claude also says `waiting` for modals that only show something (the history
    view, `/config`). Those carry `waitingFor: "dialog open"` and leave the
    session in the state it was in.
- **needs reply**: the gate kept the turn's ask.
- **failed**: the agent's own error.
- **done**: the turn finished.
- **working**: busy, a turn that ended only to wait for its own background work,
  or a finished turn the hub is still reading.
- **idle**: fresh, or dismissed. A dismissed prompt shows as what the session would
  otherwise be, `working` mid-turn.

### How long a state lasts

- Focusing the window of a `done` session reads it, as `x` does.
- `needs-reply` and `failed` stay until you answer, dismiss them, or their next
  turn starts.
- Turns, dismissals and what each session is called live in
  `~/.local/state/agent-hub/state.json`, so a daemon restart keeps them.
- A turn a restart caught open or unread is read if its agent has since gone idle,
  since its ending went unheard. One still running carries on.
- pi also keeps its record on the session's branch and hands it back when it
  attaches.

## In the agent's own TUI

Each agent's TUI repeats the row the hub has for _that session_, not an overview
of the others.

- It shows the state as a word and, for `needs reply` and `failed`, the ask or the
  failure behind it, truncated. `idle` draws nothing. Both also show the label.
- Claude Code's status line (`modules/programs/claude-code/statusline.sh`) asks
  `agent-hub status --session-id …` on each refresh. It prints nothing when the
  daemon is down, and `agent-hub` joins that script's PATH only on hosts with the
  hub enabled.
- pi gets its row pushed over the connection it is attached on: the footer paints
  the state (`parent/chrome/hub.ts`), the editor border the label, the step or the
  ask, and the input line the drafted reply (`parent/identity.ts`). It reattaches
  when the daemon restarts or starts later.
- The row can outlast the turn: it can still say the turn asked something, failed,
  or is being read after the TUI looks idle again.
- `agent-hub status` takes `--session-id` or `--pid` (either finds the row; a pid
  under the agent's finds it too), and `--json` for the whole row as the bar sees
  it.

## Sessions sharing a working tree

Before each turn the hub tells a session about the others in its git working tree
(`agent_hub/peers.py`), splitting them into working now and just open.

- It warns them to speak up before a commit, a rebase or a reset.
- It mentions shared uncommitted changes only when `git status` has some, and
  offers a worktree only beside a busy peer.
- pi puts the note in its system prompt (`claude-peers.ts`).
- Claude Code's `UserPromptSubmit` hook adds it to the prompt only when it changed
  since that session last heard it, and says so once when the others have gone.
- That hook is the one the prompt waits on, so it gives up on the hub after a
  second.

## Ended sessions

- A session the hub named is kept when it ends, with the command that resumes it
  (`claude-work --resume …` for a work session).
- `agent-hub recent` lists them, newest first, and the popout shows the latest.
- Resuming one from the popout opens the `terminal` from the hub's config through
  niri, so it gets the desktop's environment as `Mod+Return` does.
- A resumed session takes its name back.
- `wt` asks the hub too: a worktree in use names the agent session in it.

## Work log

Every turn the hub reads an ending for is a line in
`~/.local/state/agent-hub/log.jsonl`: when, which session and agent, its label, how
the turn ended, what it did and what it asked. Lines older than 90 days go when the
daemon starts.

- `agent-hub log` prints the last day (`--since 3h`, `yesterday`, `2w` or a date)
  grouped by session, each with the command that resumes it; `--json` prints the
  lines themselves.
- `agent-hub find WORDS…` lists the sessions whose labels, did-lines or asks hold
  every word, with their resume commands.
- A verdict you flagged with `w` shows there as `wrong <state>`. A `needs-reply` you
  dismissed without going to it shows as `unopened needs-reply`, a weaker sign, since
  you may only not care. Both name the session and turn.
- Each row carries its last three endings (`history`), which the popout shows
  under the selected session, ended ones included.
- Both commands read the file directly, so they work without the daemon.

## How it works

- The daemon is `agent-hub daemon` (`pkgs/agent-hub/agent_hub/`), a user service.
  - `protocol` defines every message and the row.
  - `model` holds the session rules, pure and tested as data.
  - `readings` says when a model is asked, and `judge` holds the prompt, the gate
    and the parsing.
  - `hub` is the shell that wires them to the socket, the registry and niri.
- Window focus comes from niri's event stream.
- The order of the `state` message is the one the popout lists and `focus-next`
  walks.
- Each row carries `reason`: why it is in its state, which the popout, the TUIs and
  `agent-hub status` all read.
- The protocol has a version. pi's build generates its TypeScript types from
  `protocol.py`, and a pi built against another version is refused with a notice to
  restart it.
- The bar plugin is `modules/desktop/dms/agent-hub/`. One socket subscription lives
  in its daemon component, which every bar's widget shares.
- pi's connection is `modules/programs/pi/extensions/parent/lib/hub.ts`, and what pi
  does with its row is `parent/identity.ts`.
- pi's registry entry is written by
  `modules/programs/pi/extensions/parent/claude-peers.ts`, for Claude Code's messaging.
- Claude Code can park a conversation in a background job under its daemon; the
  front's entry gets `parkedJobId`. agent-hub's daemon then shows the job's entry in
  the front's place, under the front's window.

## Limits

- Only top-level sessions register. A Claude Code started from inside another one
  (`CLAUDE_CODE_CHILD_SESSION` set) and headless runs never show up.
- Background sessions `claude agents` lists with no pid stay out of the hub.
- `claude-work` shares the personal profile's registry through the
  `~/.claude-work/sessions` symlink home-manager owns. A hand-made link there blocks
  the first switch; remove it first.

## Working on it

- A switch doesn't reload the bar plugin: run `systemctl --user restart dms` to see
  a QML change.
- `agent-hub demo` puts fake sessions in every state on the bar until Ctrl-C.
- `journalctl --user -u agent-hub` shows the daemon's log; on the Mac it is
  `~/Library/Logs/agent-hub.log`. It has one line per state change: the session,
  its old and new state, what settled it (`words`, `model`, `error`) and how many
  characters it read. Never the words themselves, as homelab's journal ships to
  Grafana Cloud; asks stay in the work log.
- The protocol tests run in every `nix build .#agent-hub`, or with
  `python3 -m unittest discover -s tests` from `pkgs/agent-hub`.
