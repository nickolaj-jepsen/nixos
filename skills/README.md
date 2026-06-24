# skills

Agent skills used in my Claude Code setup, kept here so they're installable in any
repo with [`npx skills`](https://github.com/vercel-labs/skills). On my own machines
home-manager symlinks this same directory into `~/.claude/skills`, so this is the
single source — published and deployed from one place.

## Install

All of them:

```bash
npx skills add nickolaj-jepsen/nixos
```

Or pick one by its subpath:

```bash
npx skills add https://github.com/nickolaj-jepsen/nixos/tree/main/skills/grill-me
```

## What's here

- **grill-me** — interview yourself relentlessly about a plan or design until every
  branch of the decision tree is resolved. Good before committing to an approach.
- **prune-comments** — strip redundant or over-long comments and docstrings down to
  the load-bearing why. Run it after generating code.
- **avoid-ai-tropes** — catalog of AI writing tells to check human-facing prose
  against and rewrite. Sourced from [tropes.fyi](https://tropes.fyi) by
  [ossama.is](https://ossama.is); credited in the skill file.
