---
name: commit
description: Create a git commit message and commit the changes.
allowed-tools: Read, Edit, Grep, Glob, Bash(git commit:*), Bash(gh pr edit:*), Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(git add:*), Bash(git branch:*), Bash(git checkout:*), Bash(git stash:*), Bash(git fetch:*), Bash(git rebase:*), Bash(git merge:*), Bash(git cherry-pick:*), Bash(git worktree:*), Bash(git reset:*), Bash(git show:*)
disable-model-invocation: true
---

When creating a commit message, follow these guidelines:

- First check `git log --oneline -10` to detect the repo's existing commit style and follow it. If no clear convention exists, use the Conventional Commits format: `<type>(<scope>): <description>`, where:
  - `<type>` is one of `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, etc.
  - `<scope>` is optional and can be anything specifying the area of the codebase affected (e.g. `auth`, `ui`, `api`).
  - `<description>` is a short summary of the change.
- The commit message should be concise (ideally under 72 characters) and written in the imperative mood (e.g. "Add feature" instead of "Added feature" or "Adding feature").
- Avoid writing a body for the commit message unless necessary. If a body is needed, separate it from the subject with a blank line and provide a more detailed explanation of the change, keep the body wrapped at 72 characters.
- If the commit includes a breaking change, include `BREAKING CHANGE:` in the body of the commit message, followed by a description of the breaking change.
- If the commit relates to an issue, include `fixes: #<issue_number>` in the body of the commit message to automatically close the issue when the commit is merged.

When committing very large changes, try to break them down into smaller commits that each represent a single logical change. This makes it easier to review and understand the history of the project.

Now, analyze the current git status and diff to generate an appropriate commit message following the above guidelines, and then stage the changes and create the commit. If there are any issues with the git status or diff (e.g. merge conflicts, unstaged changes), provide a clear explanation of the problem and how to resolve it instead of creating a commit.
