# PR descriptions and commits

The reader is a reviewer with little context, or someone running `git log` a year from now.

## PR descriptions

- Open with what changes for a user or caller, and why, in a sentence or two. Not "This PR…".
- Past a couple of paragraphs, split it with headers named for what's under them: `### wt clean`, `### Removed`, `### Testing`. A reviewer jumps to the part they care about.
- Say how it works only where the diff doesn't make it obvious. Say what you traded away.
- Say how you tested it, and where a reviewer should look hardest.
- Link the issue. Update the description when review changes the approach.

## Commits

When this skill is loaded:

- Follow the repo's style. With none, use conventional commits: `type(scope): summary`.
- The subject says what changed, in the imperative, and stands alone.
- Add a body only when the why isn't obvious from the subject and diff. It says the problem and the reason for this fix, not the steps.

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

`wt clean` now picks worktrees in a checklist instead of fzf.

### What changes

- Worktrees whose branch is already in the default branch start ticked.
  Closing them loses nothing.
- The rest start unticked.
- A new BRANCH AFTER column says which branches go.

### Dependencies

fzf is no longer needed at runtime. questionary is new.
```

The first version announces and labels. The second keeps the headers but fills them with facts: what changed, what "safe" means, and what a packager needs to know.
