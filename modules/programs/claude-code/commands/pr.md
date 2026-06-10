---
name: pr
description: Create a pull request from the current branch.
allowed-tools: Read, Grep, Glob, Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(git branch:*), Bash(git checkout:*), Bash(git remote:*), Bash(git rev-parse:*), Bash(git show:*), Bash(gh pr *), Bash(git push:*)
disable-model-invocation: true
---

Create a pull request from the current branch to the default branch. Follow these steps:

1. Check for a PR template (`.github/pull_request_template.md` or similar) and use it if present. Otherwise use the default format below.
2. Analyze the current branch's commits since diverging from the base branch using `git log` and `git diff`.
3. Determine the base branch (usually `main` or `master`).
4. Write a concise PR title (under 70 characters) using conventional commit style.
5. Write a PR body with:
   - A `## Summary` section with 1-3 bullet points describing the changes.
   - A `## Test plan` section with a checklist of testing steps.
6. Create the PR using `gh pr create`.

If you're on the default branch, create a new branch first using `git checkout -b <branch-name>` before creating the PR. The branch name should be descriptive of the changes being made (e.g. `feat/auth-add-login`, `fix/ui-button-alignment`, etc.).
If the branch hasn't been pushed yet, push it with `git push -u origin HEAD` first.
If a PR already exists for this branch, inform the user instead of creating a duplicate.

Before creating the PR, MAKE SURE to present you title and body to the user and ask for confirmation. If the user requests changes to the title or body, allow them to edit it before proceeding.
