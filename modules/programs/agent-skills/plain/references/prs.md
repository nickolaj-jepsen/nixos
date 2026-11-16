# PR descriptions and commits

The reader is a reviewer with little context, or someone running `git log` a year from now.

PR descriptions:

- First line: what changes for a user or caller, and why. Not "This PR…".
- Then how it works, only where the diff doesn't make it obvious, and what you traded away.
- How you tested it, and where a reviewer should look hardest.
- Link the issue. Update the description when review changes the approach.
- Short prose, plus a few bullets for separate changes. Usually under 150 words.

Commits, when this skill is loaded:

- Follow the repo's style. With none, conventional commits: `type(scope): summary`.
- The subject says what changed, in the imperative, and stands alone.
- A body only when the why isn't obvious from the subject and diff: the problem and the reason for this fix, not the steps.

## Example

```text
## Summary
This PR introduces a new interactive selection experience for `wt clean`,
leveraging questionary to provide a checklist UI. This is a significant
improvement over the previous approach.

## Changes
- **Interactive checklist**: Added questionary-based selection
- **Smart defaults**: Safe worktrees are now pre-selected
- **Improved UX**: Better visibility into what gets removed

→
`wt clean` picks worktrees in a checklist instead of fzf. The ones whose
branch is already in the default branch start ticked, since closing them
loses nothing; the rest start unticked. A new BRANCH AFTER column says
which branches go. fzf is no longer a runtime dependency; questionary is.
```

The first version announces and labels. The second says what changed, what "safe" means and what a reviewer should know about dependencies, in fewer words.
