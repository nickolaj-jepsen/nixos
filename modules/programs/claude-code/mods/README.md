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
  VS Code, Sublime Merge, the file manager or Ghostty. Rows that can't run say
  why. Needs `git`, and `gh` for the pull request.
- **answer**: when a turn ends on a round of questions or a numbered pick
  list, a band row offers a form for it in a pane: one question per screen,
  its options plus "Write your own answer" as numbered entries. A number,
  Enter or a click picks one and opens a note field; Enter there, empty or
  not, goes on. `b`, `f`, `s` and `r` go back, forward, skip and to the
  review, which writes the reply you would have typed (`Q1: yes`, `Q2: B`,
  `do 1, 3`) into the prompt, above any draft, for you to send. Open it with
  `/answer` or the band's button; for a key, bind `app:cycleDiffBase` in the
  `Global` context of `~/.claude/keybindings.json` (I use `alt+a`). Its
  parser also backs the pi half in
  `modules/programs/pi/extensions/parent/answer.ts`.
