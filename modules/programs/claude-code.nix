{
  pkgs,
  config,
  ...
}: let
  inherit (config.fireproof) username;
  grafanaMcpWrapper = pkgs.writeShellScript "grafana-mcp-wrapper" ''
    set -euo pipefail
    export $(grep -v '^#' ${config.age.secrets.grafana-mcp-env.path} | xargs)
    exec ${pkgs.mcp-grafana}/bin/mcp-grafana "$@"
  '';

  refactorGuidelines = ''
    - Remove any duplicate code by creating reusable functions or modules.
    - Ensure that the refactored code is well-tested by running existing tests and adding new tests if necessary to cover the changes.
    - Make sure that all tests makes sense, remove any redundant or irrelevant tests that do not add value.
    - If a 3rd party library could significantly simplify the code, suggest it to the user and wait for approval before adding it.
  '';

  mkRefactorCommand = {
    lang,
    tools,
    extra ? "",
  }: ''
    ---
    name: refactor-${lang}
    description: Refactor ${lang} code to improve readability, maintainability, or performance without changing its external behavior.
    allowed-tools: Read, Write, Grep, Glob, Edit, ${tools}
    disable-model-invocation: true
    ---

    When refactoring ${lang} code, consider the following best practices:
    ${extra}
    ${refactorGuidelines}

    Analyze the current ${lang} codebase to identify areas that could benefit from refactoring based on the above best practices. Then, apply appropriate refactoring techniques to improve the code while ensuring that its external behavior remains unchanged. After refactoring, run tests to verify that everything still works as expected.

    If there are any uncommitted changes in the repo, focus on refactoring the current changes instead of the entire codebase.
  '';
in {
  config = {
    age.secrets.grafana-mcp-env = {
      rekeyFile = ../../secrets/grafana-mcp-env.age;
      mode = "0600";
      owner = username;
    };

    fireproof.home-manager = {
      # Mutes warning about installMethod by placing the wrapped binary in ~/.local/bin
      home.file.".local/bin/claude".source = "${config.home-manager.users.${username}.programs.claude-code.finalPackage}/bin/claude";

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
        package = pkgs.claude-code;
        mcpServers = {
          grafana = {
            command = toString grafanaMcpWrapper;
            args = [];
          };
        };
        commands = {
          "commit" = ''
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
          '';

          "pr" = ''
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
          '';

          "refactor-python" = mkRefactorCommand {
            lang = "Python";
            tools = "Bash(uv sync), Bash(uv run:*)";
            extra = ''
              - Follow PEP 8 style guidelines for Python code to ensure consistency and readability.
              - Use type hints for function signatures.
              - Prefer dataclasses or Pydantic over raw dicts for structured data.'';
          };

          "refactor-rust" = mkRefactorCommand {
            lang = "Rust";
            tools = "Bash(cargo fmt), Bash(cargo clippy), Bash(cargo test)";
            extra = ''
              - Follow Rust's official style guidelines (rustfmt) to ensure consistency and readability.
              - Prefer `impl` blocks over standalone functions where it improves API ergonomics.
              - Use the `?` operator for error propagation instead of manual `match`/`unwrap`.
              - Prefer iterators and combinators over manual loops where readability isn't hurt.'';
          };

          "refactor-typescript" = mkRefactorCommand {
            lang = "TypeScript";
            tools = "Bash(npm run fmt), Bash(npm run lint), Bash(npm test), Bash(pnpm run fmt), Bash(pnpm run lint), Bash(pnpm test)";
            extra = ''
              - Follow a consistent coding style and use a linter (e.g. ESLint) to enforce it.
              - Avoid using the `any` type, and prefer more specific types to improve type safety and readability.
              - Use async/await for asynchronous code to improve readability and maintainability, and avoid callback hell.
              - Prefer `interface` over `type` for object shapes (better error messages, extendability).
              - Use `const` assertions and discriminated unions over enums.
              - Always prefer erasableSyntaxOnly-compatible TypeScript — avoid `enum`, `namespace`, parameter properties, and other non-erasable syntax.'';
          };
        };

        settings = {
          voiceEnabled = true;
          hooks = {
            Notification = [
              {
                matcher = "permission_prompt|idle_prompt";
                hooks = [
                  {
                    type = "command";
                    command = "printf '\\a' > /dev/tty";
                  }
                ];
              }
            ];
          };
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
              "Bash(git show:*)"
              "Bash(git remote:*)"
              "Bash(git rev-parse:*)"
              "Bash(git reset:*)"
              "Bash(git tag:*)"
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
              "Bash(tree:*)"

              # Cargo
              "Bash(cargo build:*)"
              "Bash(cargo test:*)"
              "Bash(cargo check:*)"
              "Bash(cargo clippy:*)"
              "Bash(cargo fmt:*)"
              # NPM / PNPM
              "Bash(npm run:*)"
              "Bash(npm test:*)"
              "Bash(npm install:*)"
              "Bash(pnpm run:*)"
              "Bash(pnpm test:*)"
              "Bash(pnpm install:*)"
              "Bash(pnpm exec:*)"
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
              # DS
              "Bash(ds:*)"

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
