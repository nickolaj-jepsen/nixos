# Agent temp space

Coding agents write their temp files wherever `TMPDIR` points, and nothing ever
removes them. On this machine that was 44 GB of `/tmp` out of 47 GB, most of it
one afternoon's downloads, while `/tmp`'s only guard was systemd's stock
ten-day rule. Agent temp now lives in `/tmp/agent`, which the janitor owns.

## The pieces

| Piece                                      | What it does                                                                 |
| ------------------------------------------ | ---------------------------------------------------------------------------- |
| `pkgs/agent-tmp`                           | The CLI: `dir`, `state`, `statusline`, `status`, `sweep`, `warn`, `warnline` |
| `modules/programs/agent-tmp.nix`           | Puts it on `PATH`, runs `sweep` on a 15-minute user timer and at login       |
| The agent wrappers                         | `claude`, `claude-work` and `pi` export `TMPDIR=/tmp/agent/<pid>`            |
| Claude's status line and `PreToolUse` hook | The cached numbers, and one line for the model under pressure                |
| pi's `agent-tmp` extension                 | The same, as a footer entry and an appended tool-result line                 |

All of it is behind `fireproof.agents.tmp.enable`, which cascades from
`dev.enable`.

## How a directory is judged

The wrapper names its directory after its own pid, and `exec` keeps that pid, so
`/tmp/agent/<pid>` is live while `/proc/<pid>` exists. A directory whose pid is
gone is _proven_ dead rather than guessed at from its mtime — which matters,
because the session that filled the disk had written to its scratchpad minutes
before.

A dead directory goes when it is older than three days, when the root is over
its 16 GB budget (oldest first), or when the filesystem drops under 10% free.
A _live_ session is never touched: the budget cannot reach it, so the only lever
is the warning line, and the agent has to give space back itself.

Before the redirect, sessions wrote to `/tmp/claude-1000/<cwd>/<uuid>`, which has
no pid to check. Those are matched against Claude Code's session registry
(`~/.claude/sessions/*.json`, which pi sessions also land in) and additionally
need an hour without a write. Unregistered paths — `/tmp/pi-*`, `/tmp/oc` — are
only ever swept by the age rule.

## Knobs

Environment variables, read by the CLI: `AGENT_TMP_ROOT`,
`AGENT_TMP_BUDGET_GIB` (16), `AGENT_TMP_MAX_AGE_DAYS` (3),
`AGENT_TMP_FREE_FLOOR_PCT` (10), `AGENT_TMP_WARN_FREE_GIB` (10),
`AGENT_TMP_WARN_EVERY_SECONDS` (600). The root, the budget and the age are meant
to be edited here rather than per host; `_LEGACY_ROOT` and `_STALE_PATHS` exist
so a test can point the walk at fixtures.

```bash
just agent-tmp          # what is here, what a sweep would free; deletes nothing
just agent-tmp sweep    # do it now
journalctl --user -u agent-tmp-sweep   # what the timer did
```

## Traps

- **A detached background job outlives the pid that named its temp dir.** Once
  the session process is gone, so is its `TMPDIR`, whatever still holds a path
  into it. `bg_run`-style jobs have to finish inside their session.
- **`sudo` resets `TMPDIR`,** so root-run commands inside an agent still use
  `/tmp`. That is why the legacy paths stay in the walk.
- **A recycled pid looks live.** The three-day rule is what eventually reaps it.
- **There is no filesystem cap.** btrfs quotas are off, and turning them on for
  one 20 GB limit costs a filesystem-wide rescan on five hosts; the budget plus
  the warning line is what exists instead.
- The status line numbers come from the sweep's cache, so they can lag by up to
  the timer's interval; the CLI refreshes them in the background once they are
  older than a minute.
