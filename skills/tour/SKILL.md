---
name: tour
description: Guide a human reviewer through a pull request or a stack of them, one PR at a time — a one-screen map per PR (intent, decisions to judge, reading order, what to skip), then stays to answer questions. Explains; never reviews, judges or comments. Run as /tour [<pr>…] [--all].
disable-model-invocation: true
argument-hint: "[<pr>…] [--all]"
metadata:
  status: in-progress
---

The user reads the code; you make that reading short. You explain what changed and where the choices are, so they spend their time on structure and decisions instead of on noise. You don't hunt bugs, grade, praise or give a verdict.

**Brevity is the product.** Every line must save the reader more time than it takes to read. The caps below are ceilings, not targets; leave out any section with nothing real in it. A long report about a long PR has failed.

## Targets

| Run             | Walks                                                                                |
| --------------- | ------------------------------------------------------------------------------------ |
| `/tour`         | The stack's layers that request the user's review, bottom-up; every layer if none do |
| `/tour 123 125` | Exactly those PRs, bottom-up, with the rest of their stack as context                |
| `/tour --all`   | Every layer of the stack                                                             |

With no arguments, the stack is the one the current branch is in. With no PR for the branch, tour the local diff against its base branch as a single PR with no GitHub steps. With nothing to diff, say so and stop.

A layer requests the user's review when their review is requested (directly or via a team), or when their latest review predates the current head: `gh pr view <n> --json reviewRequests,latestReviews,headRefOid` against `gh api user -q .login`.

## Gather

- **Stack:** `gh stack view --json` when it works. Otherwise follow base branches with `gh pr list --json number,title,headRefName,baseRefName,url`: the PR whose head is this PR's base is the layer below. A PR targeting the default branch with nothing above it is a stack of one.
- **Header facts:** title, body, `additions`, `deletions`, `changedFiles` per layer. Don't read diffs of layers you aren't walking, unless explaining a walked layer needs one; then read only what you need.
- **Commits:** `git fetch -q origin pull/<n>/head <baseRefName>`, then use `baseRefOid` and `headRefOid` from `gh pr view`. Read files with `git show <oid>:<path>` and search with `git grep <pattern> <oid>`. If you need a working tree, check the PR out in the user's checkout only when it is clean; otherwise create a worktree at the head. Never touch uncommitted work.
- **Noise:** run `bash <skill-dir>/scripts/noise.sh <baseRefOid> <headRefOid>`. It classes every file as `lock`, `generated`, `binary`, `renamed`, `format`, `moved` or `edit`, with line counts. Read only the `edit` files' diffs (`git diff -M <base>...<head> -- <files>`). The rest is the Skip line; spot-check a `moved` or `format` file only if its neighbours make the class look wrong.

## The map

One per walked PR. Small PRs (under about 150 changed lines in `edit` files, or one logical change) get the header, Intent and Skip only.

```
Stack  main ← #120 schema ← ▶#121 api ← #122 ui
#121 · <title> · <n> files, +<a> −<d>

Intent   <one line: what this PR is for, in the author's terms if the body says>

Decisions                     ≤5, choices the reader should judge
- <new API shape, data model, dependency, removed behaviour, deviation from the codebase's pattern — `path`>

Look closely                  ≤3, where a mistake would hide
- <`path:line` — what to check, not a verdict>

Order                         ≤10 steps, foundations first
1. <Step name>   <files, basenames unless ambiguous>
2. ...

<Hardest step>: ≤6 lines explaining how it works, so reading it goes fast.
Deep dives: 1 <topic> · 2 <topic>          ≤4, offered not written

Cross-layer   ≤3: code in the wrong layer, undoing a lower layer, or relying on something above
Skip (<n>, marked viewed)   <n> moved, <n> renamed, <n> format-only, <files or globs for generated and locks>

<PR files URL> · "next" for #<n>
```

- **Stack line:** every layer, `▶` on each one you'll walk. Omit it for a stack of one.
- **Order:** group by logical step, not by file or folder: a contract, its implementation and its tests are one step. Order so each step only depends on earlier ones. A step that's large but mechanical (a rename across 40 call sites) is one line with a count.
- **Decisions and Look closely:** cite where. Draw on the PR body, but treat its claims as claims; say when the code disagrees.
- **Cross-layer:** check files that other layers also touch, and the walked layer's use of what lower layers introduce.
- **Words:** no adjectives about quality, no restating the title, no hedging.

## Walk

- Show the first map and wait. On "next", show the next walked PR's map. After the last, say the tour is done and that you're here for questions.
- **Viewed marks:** before showing a PR's map, mark every non-`edit` file viewed so it starts collapsed, using its new path:

  ```bash
  gh api graphql -f query='mutation($id:ID!,$p:String!){markFileAsViewed(input:{pullRequestId:$id,path:$p}){clientMutationId}}' -f id="$(gh pr view <n> --json id -q .id)" -f p=<path>
  ```

  Leave them marked afterwards. This is the only write to GitHub you make.

## Questions

- Answer in 10 lines or fewer unless asked for more, citing `path:line`.
- "Explain <topic>", or a deep-dive number, gets a deep dive: how that part works and why, in about 15 lines. Add a diagram only when it shows a flow or relationship faster than prose: write the dive to `tour/<pr>-<topic slug>.md` in the project's store (`agent-notes root --ensure` gives its path; without it, use `$TMPDIR`), render it with the `mermaid` skill (Claude Code: the Skill tool; pi: read its SKILL.md), and give the SVG path along with the answer in chat.
- Don't edit code, post comments, submit reviews or approve, even when a question sounds like a finding; answer it and leave the action to the user.
- On "done", remove any worktree you created and switch a checkout you changed back to where it was.
