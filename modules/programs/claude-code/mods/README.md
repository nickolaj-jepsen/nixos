# Claude Code mods

Plugins with a hooks module, built and loaded by my home-manager config and
published through this repo's marketplace (`.claude-plugin/marketplace.json`).

## Install

```bash
claude plugin marketplace add nickolaj-jepsen/nixos
claude plugin install spellfix@nickolaj-jepsen
claude plugin install linear-issue@nickolaj-jepsen
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
