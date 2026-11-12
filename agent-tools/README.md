# agent-tools

Plugins for [Claude Code](https://claude.com/claude-code), some shared with the
[pi](https://github.com/earendil-works/pi) coding agent.

- [Install](#install)
- [Plugins](#plugins): [linear-issue](#linear-issue), [answer](#answer)
- [Skills](#skills)
- [Development](#development)

## Install

```bash
claude plugin marketplace add nickolaj-jepsen/nixos
claude plugin install linear-issue@nickolaj-jepsen
claude plugin install answer@nickolaj-jepsen
```

My nix build tests each plugin against the Claude Code version it ships with. A
marketplace install gets no such check, so a Claude Code update can break one.

## Plugins

### linear-issue

Turns a thought, or something Claude Code flagged, into a Linear issue you approve
before it's filed.

![The You should know card flags a test script that can't fail; Learn more explains it, and 3 drafts a Linear issue from it](demos/linear-issue-ysk.gif)

- `/linear [what to file]` drafts from your note, or from the recent conversation
  when the note is empty.
- The You should know card gets a **Linear issue** button (usually `3`) once you
  press Learn more, which drafts from the card's insight.
- The draft fills in title, description, team, priority, status and labels; every
  field is editable.
- An open issue that already covers it adds a **Comment on KEY-123** choice.
- **Create**, or **Create & open** in the browser.
- `Esc` hides the draft to a chip above the prompt: `8` reopens it, `9` twice
  discards it.

Needs a Linear MCP server, connected and signed in.

<details>
<summary>Demo: drafting with <code>/linear</code></summary>

![/linear drafts an issue, the title is rewritten, Esc hides the draft and 8 reopens it](demos/linear-issue.gif)

</details>

### answer

A form for the round of questions or numbered pick list a turn ended on, which
writes your reply into the prompt.

- A row above the prompt offers the form when a turn ends on questions; `/answer`
  or a click opens it.
- One question per screen: numbered options, plus a last entry to write your own.
- Answer with a number, `Enter` or a click, and add a note under any answer.
- `y` takes the recommendation, `m` picks several options (`Q3: A, C`).
- `h` / `l` / `s` / `r`: back, next, skip, review.
- The review writes one line per answer into the prompt, above any draft. You send
  it.
- Works with the mouse alone, and in the desktop app, VS Code and mobile with their
  own controls.
- Answers last the session: a turn a background task starts keeps them, your own
  send drops them.
- pi has the same form, from the same parser (`core/forms.ts`).

Keys, in `~/.claude/keybindings.json` (a mod can't take the keyboard itself):

```json
{
  "bindings": [
    { "context": "Chat", "bindings": { "alt+a": "abovePrompt:focus" } },
    {
      "context": "AbovePrompt",
      "bindings": { "j": "abovePrompt:next", "k": "abovePrompt:previous" }
    },
    {
      "context": "AbovePromptInput",
      "bindings": { "escape": "abovePrompt:previous" }
    }
  ]
}
```

- `alt+a` lands on the offer row, and `Enter` opens the form.
- `j` / `k` move between entries.
- `Esc` in a field steps back onto the form instead of out to the prompt.

Options (`claude plugin configure answer`):

- `scrollTranscript` (off): leave a question's body out of the form and scroll the
  transcript to it instead.

Load it first in `CLAUDE_CODE_PLUGIN_DIRS`: an open form takes the band above the
prompt to itself.

## Skills

None here yet. My standalone skills are in [`skills/`](../skills/README.md).

## Development

### Layout

Laid out to be split into a repository of its own. Each `plugins/<name>/` is a
Claude Code plugin, built by `mkToolMod` in `modules/programs/claude-code/default.nix`:

- `core/`: harness-free TypeScript shared with pi. One file, no imports, no Node, no
  DOM.
  - Tests are `core/*.spec.ts`, run by vitest (`npm test`) and by
    `pkgs/agent-tools`.
  - `claude plugin test` runs only `*.test.ts(x)`, so the two never overlap.
- `claude/`: the mod. `hooks/hooks.json` names `../claude/register.tsx`.
- Plugin root: only `hooks/`, `.claude-plugin/` and `types/`.
- The pi half is in `modules/programs/pi/extensions/parent/`, reading the core
  through `parent/lib/<name>`, a symlink the pi leaf replaces with a copy at build
  time.
- No plugin imports the agent-hub client. One that needs the hub isn't a plugin.

| Plugin         | `core/` | pi half |
| -------------- | ------- | ------- |
| `answer`       | yes     | yes     |
| `linear-issue` | no      | no      |

### Traps

None of these show up in `tsc`:

- The hooks module can't re-export `register`: the engine reads `on(...)` calls from
  the file `hooks.json` names. Point `hooks.json` at the real module.
- `types/index.d.ts` must be self-contained, with no `import`. It restates the shapes
  `core/` owns, so `tsc -p` flags drift.
- vitest takes the nearest `tsconfig.json`, and the plugin's one needs types only
  `just dev-setup` lays. `core/tsconfig.json` is there to be nearer.

### Demos

Each plugin's GIFs are recorded from a live Claude Code session. Re-record after
changing what a plugin draws or its keys:

```bash
just demo linear-issue       # /linear: draft, edit the title, hide, reopen
just demo linear-issue-ysk   # the You should know card's Linear issue button
```

- `demos/record.sh` drives the session with `skills/claude-mod-dev`'s driver
  (loading the checkout's plugins), records it with asciinema and renders the GIF
  with agg at 1.8× speed.
- `demos/<name>.sh` holds the steps, and may fill the session's folder first.
- Demos, not tests: a run that goes another way keeps the old GIF. Run it again;
  `linear-issue-ysk` often takes a few, since the card is the side agent's call.
- Runs use your account (`linear-issue-ysk` on Haiku). A plugin needing a connector
  gets your full profile.
- Nothing is filed: Linear's write tools stay unapproved, and a run whose log shows
  one is dropped.
