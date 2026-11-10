# Claude Code mods

Plugins with a hooks module, built and loaded by my home-manager config and
published through this repo's marketplace (`.claude-plugin/marketplace.json`).

## Install

```bash
claude plugin marketplace add nickolaj-jepsen/nixos
claude plugin install spellfix@nickolaj-jepsen
claude plugin install linear-issue@nickolaj-jepsen
claude plugin install git-menu@nickolaj-jepsen
claude plugin install answer@nickolaj-jepsen
```

My nix build validates and tests each mod against the Claude Code version it
ships with. An install from the marketplace gets no such check, so a Claude
Code update can break one.

## What's here

- **spellfix**: picks fixes for misspelled words in the prompt draft with
  hunspell and Haiku. One Haiku call answers every flagged word, adds the ones
  it calls correct to the personal word list, and finds real-word typos
  hunspell can't (`form` for `from`). Needs `hunspell` and its dictionaries
  installed; set the executable, dictionaries and personal word list in the
  plugin's options (`claude plugin configure spellfix`). Its picker is
  the band button above the prompt; to open it from the keyboard, bind
  `app:toggleDiffNoiseFilter` in the `Global` context of
  `~/.claude/keybindings.json` (I use `ctrl+q`), which works on any draft.
- **linear-issue**: drafts a Linear issue for approval from the You should know
  card or `/linear`. Needs a Linear MCP server connected and signed in.
- **git-menu**: `/git` opens the checkout's repository, branch, commit or pull
  request on GitHub, GitLab or Codeberg, links the compare page for a new pull
  request, and copies the branch, SHA or PR URL; `/open` hands the checkout to
  VS Code, Sublime Merge, the file manager or Ghostty, `/open plan` lists the
  checkout's notes (`.agents/store`) for the editor, and `/open diff` opens
  [tuicr](https://github.com/agavra/tuicr) on the changes in a new Ghostty
  window and tells the model how to read your comments back. Rows that
  can't run say why. Needs `git`, `gh` for the pull request, and `tuicr` and
  Ghostty for `/open diff`.
- **answer** (in `agent-tools/plugins/answer`, with the pi half's shared core):
  when a turn ends on a round of questions or a numbered pick
  list, a row in the band above the prompt offers a form for it, drawn there
  too (a pane would dock beside the transcript on a wide terminal). A rule
  parts it from the chat and carries every question's label: which are
  answered, which is shown, and a click to go to one. Under it is one
  question per screen, its options as numbered entries and a last one to
  write your own answer in, which becomes a field when picked. A number, Enter or a click answers and asks for a note
  right under the answer; Enter there, empty or not, goes on to the next
  question unanswered, or to the review. `y` takes the recommendation,
  whatever it names, and `m` lets several options be one answer
  (`Q3: A, C`); a recommendation that names several starts that way. A
  recommendation beside lettered options shows under them with its reason.
  `h`, `l`, `s` and `r` go back, on, skip and to the review, which writes
  the reply you would have typed into the prompt, above any draft, for you
  to send: one line per answer, a note indented under its own. The mouse
  works alone: an option's detail lines pick it too, and a button that
  leaves a question saves what a field holds. The band shares its half of
  the screen with the prompt box. An open form stands 20 rows tall whatever
  it shows, its keys on the last row, taller only for a question that needs
  it; it has the band to itself (what the mods beneath draw there waits,
  so list this mod first in `CLAUDE_CODE_PLUGIN_DIRS`) and cuts a long
  question body to the rows left after the entries. A draft of several
  lines that leaves it short of that height is set aside while it is open
  and handed back when it folds. A second fill takes the first one's
  place. A turn a background task wakes leaves the form and its answers
  alone; only your own send drops them. A mod can't take the keyboard, so
  three bindings in `~/.claude/keybindings.json` make it usable from the
  keys: `abovePrompt:focus` in the `Chat` context (I use `alt+a`) lands on
  the row, where Enter opens the form; `j`/`k` on
  `abovePrompt:next`/`abovePrompt:previous` in `AbovePrompt` move between
  entries; and `escape` on `abovePrompt:previous` in `AbovePromptInput`
  steps out of a field onto the form instead of out to the prompt.
  `/answer` or a click opens it too, but leaves the keys with the prompt,
  where only the digits reach it. It needs nothing installed: the parser and
  the draft are its own, kept in the session.
