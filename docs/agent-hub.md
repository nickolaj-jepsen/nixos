# agent-hub

A daemon that knows every live pi and Claude Code session, on every dev host:
what each one is called, the step it is on, and how its last turn ended. Each
agent's TUI shows the hub's row for its own session. On a niri desktop
there is also the DMS bar, an overview of all of them and a quick way to the
ones that want you: it shows a dot per session that isn't idle.

Elsewhere (a server, the Mac) the hub runs headless: no windows, no toasts,
and it polls the registry instead of watching it. Its socket is
`$XDG_RUNTIME_DIR/agent-hub/hub.sock`, or `~/.local/state/agent-hub/hub.sock`
where there is no runtime dir.

- `Mod+B` opens the popout with the longest-waiting session selected; `Enter`
  (or a click) focuses its window, `x` dismisses a finished one, `j`/`k` move
  and `g`/`G` jump to the ends. Idle sessions are listed too, dimmed, then
  the last few that ended: `Enter` on one resumes it in a new terminal.
- `Mod+Shift+B` (`agent-hub focus-next`) jumps straight to the next session that
  wants you, cycling on repeat.
- `Mod+Ctrl+B` (`agent-hub toggle`) dismisses the finished turn of the session
  you're looking at, or brings back the one you dismissed.
- A toast fires when a session you aren't looking at comes to want you;
  clicking it focuses the session.

The bar never answers anything: you answer in the agent's own terminal.

## Naming and judging

The hub reads every session the same way, whichever agent runs it. At a turn's
start it asks a model what the work is called (`label`), the step in flight
(`doing`), a sentence about the session and its tags; when the turn ends, the
same prompt also asks how it ended, what it did, what it asks of you and the
reply you would likely type. One prompt and one parser (`agent_hub/judge.py`)
serve both agents.

The model reads a digest, not the transcript: the latest requests, the files
touched, the commands run and whether they failed, background jobs still out,
and the turn's closing words. The hub builds it from the agent's own file:
Claude's transcript (`agent_hub/claude.py`) or pi's session file along its
current branch (`agent_hub/pi.py`). A prompt that only agrees ("ok", "thanks")
is not worth a reading.

- **pi** attaches to the hub for the session's life (`parent/lib/hub.ts`) and
  tells it each turn's start and end, its session file, and what the file
  can't: background jobs still running and whether the run ended on an error.
  The hub asks pi to run the call, so it goes through pi's own side model and
  shows in `/cost` (`session label`, `session ask`). Every turn end is read:
  the reply draft needs it.
- **Claude Code** reaches the hub through `agent-hub hook` (set in
  `modules/programs/claude-code/default.nix`); the hub reads the transcript and
  runs `claude -p --model haiku` as the session's own profile
  (`CLAUDE_CONFIG_DIR`, which `SessionStart` reports), so a `claude-work`
  transcript stays on the work account. Each reading is a process, so a named
  session is renamed at most every ten minutes, and a turn end goes to the
  model only when its words don't settle it: a long turn that looks done, or
  one with background jobs out. A hook can name a session before the registry
  lists it; the hub keeps it while its pid runs, and `SessionEnd` lets it go.

A turn starts and ends on the agent's own word: pi's messages, Claude's
`UserPromptSubmit` and `Stop` hooks. The registry only stands in where that word
never comes: a session going busy with no turn open starts one, and one going
idle mid-turn ends it unread (Esc fires no `Stop`). A new turn cancels the
reading of the last one's ending, and a reading that lands late is dropped
(`agent_hub/model.py` holds these rules, `agent_hub/readings.py` the calls).

A reading that fails falls back to the closing words: a question in them is an
ask. Three failures in a row, or 200 readings, and the session is not asked
again. A name you chose (`/name` in pi, `/rename` in Claude Code) outranks the
label; until then pi's session name follows it, so `/resume` lists it.

## States

In the order the popout lists them. The first five want you. Focusing the
window of a `done` one reads it, as `x` does. `needs-reply` and `failed` stay
until you answer, dismiss them, or their next turn starts.

- **asking**: a dialog is open that wants an answer. Its entry in the session
  registry (`~/.claude/sessions`) says `status: "waiting"`. Claude Code writes
  that itself, with a `waitingFor` naming the dialog (`permission prompt`,
  `input needed`), and its `PermissionRequest` hook (`agent-hub hook`, set in
  `modules/programs/claude-code/default.nix`) sends the daemon a one-line label
  of the call. pi reports its own while pi-permission-system has a dialog open. Claude also says `waiting` for modals
  that only show something (the history view, `/config`): those carry
  `waitingFor: "dialog open"` and leave the session in the state it was in.
- **needs reply**, **failed**: how the last turn ended, by the hub's reading. A
  pi turn that ended on an error failed whatever the model says.
- **stalled**: a turn whose transcript hasn't moved for 15 minutes, with what it
  is still running when the transcript shows a command out. A long build counts
  too: the hub can't tell slow from stuck, only how long it has been quiet.
- **done**: the turn finished what was asked.
- **working**: busy, a turn that ended only to wait for its own background jobs
  (Claude's, or pi's `bg_run`), or a finished turn the hub is still reading (it
  reads before it shows the ending). A dev server it left running for you
  doesn't count.
- **idle**: fresh, or dismissed.

Finished turns, dismissals and what each session is called live in
`~/.local/state/agent-hub/state.json`, so a daemon restart keeps them; a turn
still running when it restarts is picked up from the registry. pi also
keeps its record on the session's branch and hands it back when it attaches.

## In the agent's own TUI

The bar is somewhere else while you work in one terminal, so each agent's TUI
repeats the row the hub has for _that session_, not an overview of the others —
that is what the popout is for. It shows the state as a word and, for `needs
reply` and `failed`, the ask or the failure behind it, truncated; `idle` draws
nothing, as it draws no dot on the bar. Both also show the label.

- Claude Code's status line (`modules/programs/claude-code/statusline.sh`)
  asks `agent-hub status --session-id …` on each refresh: one subscribe, one
  `state` message, hang up. It prints nothing when the daemon is down, and
  `agent-hub` joins that script's PATH only on hosts with the hub enabled.
- pi gets its row pushed over the connection it is attached on, so it costs no
  process per repaint: the footer paints the state (`parent/chrome/hub.ts`),
  the editor border the label, the step or the ask, and the input line the
  drafted reply (`parent/identity.ts`). It reattaches when the daemon restarts
  or starts later; without a hub the label is the first request cut to a name.

The row is the hub's, so it can outlast the turn: its reading says the turn
asked something, failed, or is still being read after the TUI looks idle again.

`agent-hub status` takes `--session-id` or `--pid` (either finds the row; a pid
under the agent's finds it too), and `--json` for the whole row as the bar sees
it.

## Sessions sharing a working tree

Before each turn the hub tells a session about the other sessions in its git
working tree: their names, which agent runs them, whether they are active, and
to warn them before a commit, a rebase or a reset. pi puts the note in its
system prompt (`claude-peers.ts`). Claude Code's `UserPromptSubmit` hook adds it
to the prompt, but only when it changed since that session last heard it, and
says so once when the others have gone. That hook is the one the prompt waits
on; it gives up on the hub after a second.

## Ended sessions

A session the hub named is kept when it ends, with the command that resumes it
(`claude-work --resume …` for a work session). `agent-hub recent` lists them,
newest first, and the popout shows the latest. Resuming one from the popout
opens the `terminal` from the hub's config through niri, so it gets the
desktop's environment as `Mod+Return` does. A resumed session takes its name
back.

`wt` asks the hub too: a worktree in use names the agent session in it.

## Work log

Every turn the hub reads an ending for is a line in
`~/.local/state/agent-hub/log.jsonl`: when, which session and agent, its label,
how the turn ended, what it did and what it asked. Lines older than 90 days go
when the daemon starts.

- `agent-hub log` prints the last day (`--since 3h`, `yesterday`, `2w` or a
  date) grouped by session, each with the command that resumes it; `--json`
  prints the lines themselves.
- `agent-hub find WORDS…` lists the sessions whose labels, did-lines or asks
  hold every word, with their resume commands.
- Each row carries its last three endings (`history`), which the popout shows
  under the selected session, ended ones included.

Both commands read the file directly, so they work without the daemon.

## Pieces

- `pkgs/agent-hub/agent_hub/`, the daemon (`agent-hub daemon`, a user
  service). `protocol` defines every message and the row, `model` the session
  rules (pure, tested as data), `readings` when a model is asked, `judge` the
  prompt and its parsing, `hub` the shell that wires them to the socket, the
  registry and niri. Window focus comes from niri's event stream; the order of
  its `state` message is the one the popout lists and `focus-next` walks. Each
  row also carries `reason`: why it is in its state, which the popout, the TUIs
  and `agent-hub status` all read.
- The protocol has a version. pi's build generates its TypeScript types from
  `protocol.py`, and a pi built against another version is refused with a
  notice to restart it, rather than half understood.
- `modules/desktop/dms/agent-hub/`, the bar plugin. One socket subscription
  lives in its daemon component, which every bar's widget shares.
- `modules/programs/pi/extensions/parent/lib/hub.ts`, pi's connection, and
  `parent/identity.ts`, what pi does with its row.
- `modules/programs/pi/extensions/parent/claude-peers.ts`, pi's registry entry,
  for Claude Code's messaging.

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
- `journalctl --user -u agent-hub` shows the daemon's log; on the Mac it is
  `~/Library/Logs/agent-hub.log`.
- The protocol tests run in every `nix build .#agent-hub`, or with
  `python3 -m unittest discover -s tests` from `pkgs/agent-hub`.
