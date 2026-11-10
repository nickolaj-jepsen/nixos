---
name: claude-mod-dev
description: Run and drive a Claude Code mod by observation — a real Claude Code session in tmux with the mod loaded from its folder, keys, captures at several widths, color screenshots and the engine's debug log. Use when developing, fixing or reviewing a mod's pane, band, command, keys or focus; before handing any mod UI change back; when a mod seems to do nothing; or when asking how a mod renders.
compatibility: Requires tmux and nix, and Claude Code signed in. Uses `claude-dev` when it is on PATH.
---

`claude plugin validate` and `claude plugin test` say a mod loads and its logic holds. They don't show where the surface docks a pane, which keys reach it, or how it looks. Those are only seen in a session, so run one and look.

Load `plugin-authoring` too: it holds the API, this skill the loop.

`scripts/tui.sh` drives a session under your own sign-in. Nothing is copied: it is `claude` in tmux, in a directory of its own so the transcript stays out of the checkout's history. It starts with no MCP servers (`--strict-mcp-config`), so the session can't reach the person's connectors; the permission mode is the profile's own. `start --full` gives it the profile as it is, for a mod that needs a connector; say so when you use it.

## Tools

| Command                                                        | Does                                                                 |
| -------------------------------------------------------------- | -------------------------------------------------------------------- |
| `tui.sh start [--cols N --lines N --cwd DIR --full] [-- args]` | New session in tmux; waits for the prompt and prints the run dir     |
| `tui.sh wait <regex> [secs]`                                   | Block until the pane matches, default 20s                            |
| `tui.sh cap [-e]`                                              | Pane text to stdout, also saved; `-e` keeps ANSI                     |
| `tui.sh type <text>` / `tui.sh keys <key...>`                  | Literal text / named keys (`Enter`, `Tab`, `Escape`, `M-a`, `Down`)  |
| `tui.sh resize <cols> <lines>`                                 | Re-lay out at another width                                          |
| `tui.sh shot [file]`                                           | Color PNG of the current pane                                        |
| `tui.sh log [regex] [n]`                                       | The debug log's last lines about the loaded folders, or your pattern |
| `tui.sh stop`                                                  | Kill the session                                                     |

`start` runs `claude-dev` where it exists: every mod from its checkout, none of the installed copies. Elsewhere it runs `claude`, so name the folder yourself and drop the installed copy of the same mod:

```bash
CLAUDE_CODE_PLUGIN_DIRS= tui.sh start -- --plugin-dir "$PWD/my-mod"
```

The session runs in `<run dir>/cwd`, an empty directory. A mod that reads the checkout (a git menu) needs `--cwd <repo>`; that session then lands in the repo's own history.

## The loop

```bash
T=skills/claude-mod-dev/scripts/tui.sh
$T start --cols 100
$T log                      # did the folder load, was a hook skipped or a tree refused
$T type '/git' && $T keys Enter
$T cap
$T resize 150 36 && $T cap  # the same pane, now docked beside the transcript
$T stop
```

`log` first: a module that did not load, a skipped hook and a tree the engine refused are each one line there. Then `cap`, since a mod can load cleanly and still draw wrong.

The folder is watched. Save a file and the hooks module reloads once the folder is quiet, with no restart; `log 'plugin-dir watch|reload'` shows it.

## Before handing back

A change to what a mod draws or to its keys is not done until you have seen it:

- `cap` at 100, 120 and 150 columns. Below 110 a pane is a box over the transcript, from 110 a sidebar beside it, and the body is narrower than the terminal while one is docked.
- every key the mod names on screen, pressed from the prompt with a draft typed and with it empty;
- `shot` once when color, dimming or a border carries meaning.

Say what you saw. If the session could not be run, say that instead of calling the work tested.

## A model turn

Most mods open from a command and need no turn. One that reacts to what the model wrote gets it cheaply from Haiku reading a file:

```bash
$T start -- --model haiku
printf '%s\n' '**Q1. Use SQLite?**' '' '- **A.** SQLite' '- **B.** Postgres' >"$run/cwd/turn.md"   # $run: what start printed
$T type 'Read turn.md with the Read tool and reply with its contents verbatim, nothing before or after.' && $T keys Enter
$T wait 'Worked for' 120
```

The reply is close to verbatim, not guaranteed; `cap` it before judging the mod. A turn takes up to a minute.

## Traps

Checked live on 2.1.319:

- A letter typed while a band is showing goes to the prompt. A band's keys work only once it has focus (`alt+a`-style chord, a click, or the person tabbing to it), so never offer a bare letter as the way in.
- A pane docks as a sidebar from 110 columns and is a box over the transcript below that. Design for both; a form that reads well as a box can be cramped as a sidebar.
- `keys Escape` followed at once by a letter is read as alt+letter. `tui.sh keys` pauses after Escape; your own `tmux send-keys` doesn't.

From the API types of 2.1.319:

- A pane the person asked for (their command, prompt or press) opens at any width. One a mod opens on its own is undrawn below 144 columns, or 110 once they have asked for that id. A press handler that opens the pane after an `await` can count as unasked.
- A bare digit arms only the hotkeys of Buttons wholly inside what is drawn, and a Button's hotkey lives only while it is mounted. Keep the Button drawn if the key must always work.

Seen in earlier sessions (2.1.308 to 2.1.316), not re-checked; confirm with the driver before designing on or around one:

- A mod can't bind a plain arrow key. Arrows in a pane came from rebinding them in the `Pane` keybinding context and hooking `ui.scroll`.
- The fullscreen terminal opens only some URL schemes on a click; a custom scheme did nothing.
- Prompt text can't be decorated (no inline highlight of a word in the draft).
- Enter in a text field clears it, and a field's `⏎ submit` hint can't be removed.
- A `SessionStart` command hook's output always carries its `SessionStart:startup says:` prefix and indent. Draw a band instead.
- `$.command.register` throws for a name a built-in or a skill already has, and `validate` and `test` don't say so. Type the command in a session.

## Limits

- The session is real: it is the person's account and uses their subscription. The built-in browser MCP still loads, and the session acts under the profile's permission mode. Keep prompts to the canned turn above.
- Clicks aren't driven. A click target is checked by its key, or by the person.
- `cap` shows text and layout, not color; `shot` rasterizes Nerd Font glyphs as boxes on some fonts.
- The built-in cards (`You should know`) can't be made to appear on demand.
