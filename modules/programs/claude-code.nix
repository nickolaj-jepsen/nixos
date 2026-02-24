_: {
  config = {
    fireproof.home-manager = {
      programs.claude-code.memory.text = ''
        This is a NixOS system. Usually built from a flake based config in ~/nixos.
        - The default shell is fish. Make sure to only use fish supported syntax.
        - If a command is not found, try [comma](https://github.com/nix-community/comma) before giving up, e.g. `, pstree`, `, ncdu .`
        - Pre-installed cli tools: git, gh, just, docker, kubectl, terraform, node, pnpm, ripgrep (rg), jq, curl, wget, tmux, tree, zip/unzip, uv, and more.
        - Always use uv (https://docs.astral.sh/uv/) for Python work
        - If you want to do a dev command, and you're in a project owned by the github.com/Digital-Udvikling org (see git remote), make sure to use the `ds` cli tool when applicable (check the `ds --help` to determine if you could use it)
      '';

      programs.claude-code = {
        enable = true;
        commands = {
          "commit" = ''
            ---
            name: commit
            description: Create a git commit message and commit the changes.
            allowed-tools: Read, Grep, Glob, Bash(git commit:*), Bash(gh pr edit:*), Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(git add:*), Bash(git branch:*), Bash(git checkout:*), Bash(git stash:*), Bash(git fetch:*), Bash(git rebase:*), Bash(git merge:*), Bash(git cherry-pick:*), Bash(git worktree:*)
            ---
            When creating a commit message, follow these guidelines:
            - Unless the repo uses a different convention, use the Conventional Commits format: `<type>(<scope>): <description>`, where:
              - `<type>` is one of `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, etc.
              - `<scope>` is optional and can be anything specifying the area of the codebase affected (e.g. `auth`, `ui`, `api`).
              - `<description>` is a short summary of the change.
            - The commit message should be concise (ideally under 72 characters) and written in the imperative mood (e.g. "Add feature" instead of "Added feature" or "Adding feature").
            - Avoid writing a body for the commit message unless necessary. If a body is needed, separate it from the subject with a blank line and provide a more detailed explanation of the change, keep the body wrapped at 72 characters.
            - If the commit includes a breaking change, include `BREAKING CHANGE:` in the body of the commit message, followed by a description of the breaking change.
            - If the commit relates to an issue, include `fixes: #<issue_number>` in the body of the commit message to automatically close the issue when the commit is merged.

            When committing large changes, try to break them down into smaller commits that each represent a single logical change. This makes it easier to review and understand the history of the project.

            Now, analyze the current git status and diff to generate an appropriate commit message following the above guidelines, and then stage the changes and create the commit. If there are any issues with the git status or diff (e.g. merge conflicts, unstaged changes), provide a clear explanation of the problem and how to resolve it instead of creating a commit.
          '';
        };

        settings = {
          permissions = {
            allow = [
              # Git
              "Bash(git status:*)"
              "Bash(git diff:*)"
              "Bash(git log:*)"
              "Bash(git add:*)"
              "Bash(git commit:*)"
              "Bash(git branch:*)"
              "Bash(git checkout:*)"
              "Bash(git stash:*)"
              "Bash(git fetch:*)"
              "Bash(git rebase:*)"
              "Bash(git merge:*)"
              "Bash(git cherry-pick:*)"
              "Bash(git worktree:*)"
              # Github
              "Bash(gh pr *)"
              "Bash(gh issue *)"
              "Bash(gh repo view *)"
              "Bash(gh run *)"

              # Unix basics
              "Bash(ls:*)"
              "Bash(find:*)"
              "Bash(wc:*)"
              "Bash(head:*)"
              "Bash(tail:*)"
              "Bash(which:*)"
              "Bash(echo:*)"
              "Bash(cat:*)"
              "Bash(mkdir:*)"
              "Bash(touch:*)"
              "Bash(dirname:*)"
              "Bash(basename:*)"
              "Bash(realpath:*)"
              "Bash(uname:*)"

              # Cargo
              "Bash(cargo build:*)"
              "Bash(cargo test:*)"
              "Bash(cargo check:*)"
              "Bash(cargo clippy:*)"
              "Bash(cargo fmt:*)"
              # NPM
              "Bash(npm run:*)"
              "Bash(npm test:*)"
              "Bash(npm install:*)"
              # Uv
              "Bash(uv sync)"
              "Bash(uv run:*)"
              # Nix
              "Bash(nix fmt:*)"
              "Bash(nix flake check:*)"
              "Bash(nix flake show:*)"
              "Bash(nix flake metadata:*)"
              "Bash(nix eval:*)"
              "Bash(nix build:*)"
              "Bash(nix develop:*)"
              "Bash(nix repl:*)"
              # Just
              "Bash(just:*)"

              # Tools
              "WebSearch"
            ];
            deny = [
              "Bash(rm -rf /)"
              "Bash(sudo rm:*)"
              "Edit(.env)"
            ];
          };
        };
      };
    };
  };
}
