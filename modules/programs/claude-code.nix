{
  pkgs,
  config,
  lib,
  ...
}: let
  inherit (config.fireproof) username;
  cfg = config.fireproof.claude-code;
  hmLib = config.home-manager.users.${username}.lib;
  homeDir = config.home-manager.users.${username}.home.homeDirectory;

  refactorGuidelines = ''
    - Remove any duplicate code by creating reusable functions or modules.
    - Ensure that the refactored code is well-tested by running existing tests and adding new tests if necessary to cover the changes.
    - Make sure that all tests makes sense, remove any redundant or irrelevant tests that do not add value.
    - If a 3rd party library could significantly simplify the code, suggest it to the user and wait for approval before adding it.
  '';

  mkRefactorSkill = {
    lang,
    extra ? "",
  }: ''
    ---
    name: refactor-${lib.toLower lang}
    description: Use when refactoring ${lang} code to improve readability, maintainability, or performance without changing its external behavior.
    ---

    When refactoring ${lang} code, consider the following best practices:
    ${extra}
    ${refactorGuidelines}

    Analyze the current ${lang} codebase to identify areas that could benefit from refactoring based on the above best practices. Then, apply appropriate refactoring techniques to improve the code while ensuring that its external behavior remains unchanged. After refactoring, run tests to verify that everything still works as expected.

    If there are any uncommitted changes in the repo, focus on refactoring the current changes instead of the entire codebase.
  '';

  claudeWorkWrapper = pkgs.writeShellApplication {
    name = "claude-work";
    runtimeInputs = [config.home-manager.users.${username}.programs.claude-code.finalPackage];
    text = ''
      export CLAUDE_CONFIG_DIR="''${CLAUDE_CONFIG_DIR:-$HOME/.claude-work}"
      mkdir -p "$CLAUDE_CONFIG_DIR"
      exec claude "$@"
    '';
  };

  workFiles = lib.mkIf cfg.work.enable {
    ".claude-work/settings.json".source = hmLib.file.mkOutOfStoreSymlink "${homeDir}/.claude/settings.json";
    ".claude-work/CLAUDE.md".source = hmLib.file.mkOutOfStoreSymlink "${homeDir}/.claude/CLAUDE.md";
    ".claude-work/commands".source = hmLib.file.mkOutOfStoreSymlink "${homeDir}/.claude/commands";
    ".claude-work/skills".source = hmLib.file.mkOutOfStoreSymlink "${homeDir}/.claude/skills";
    ".claude-work/plugins".source = hmLib.file.mkOutOfStoreSymlink "${homeDir}/.claude/plugins";
  };
in {
  options.fireproof.claude-code.work.enable =
    lib.mkEnableOption "claude-work wrapper sharing the personal claude-code config via ~/.claude-work";

  config = {
    fireproof.home-manager = {
      # Mutes warning about installMethod by placing the wrapped binary in ~/.local/bin
      home.file = lib.mkMerge [
        {
          ".local/bin/claude".source = "${config.home-manager.users.${username}.programs.claude-code.finalPackage}/bin/claude";
        }
        workFiles
      ];

      home.packages = lib.optional cfg.work.enable claudeWorkWrapper;

      programs.claude-code.context = ''
        # Global preferences

        ## Environment
        - NixOS — declarative & immutable. Imperative installs (`apt`, `npm -g`, global `pip`) and `/etc` edits won't persist; system changes go through the flake at `~/nixos`. For a one-off tool, use [comma](https://github.com/nix-community/comma): `, pstree`, `, ncdu .`

        ## Tooling
        - Language toolchains — prefer uv (Python) and pnpm (Node), but defer to whatever the repo already uses.
        - Git: rebase over merge — even if I ask to "merge" — unless I explicitly say "use merge over rebase".
        - Digital-Udvikling repos (check git remote): use the `ds` CLI when applicable (run `ds --help` to see what it covers).

        ## Code style
        - Comments earn their place. The code already states *what* it does — don't restate it. Comment only what a competent reader can't recover from the code: the load-bearing *why* (intent, a gotcha, a non-obvious tradeoff). If nothing qualifies, write no comment.
        - Default to one line. Give the minimal why and stop; run past a line only when the rationale genuinely can't compress. Length is not thoroughness.
        - Docstrings state the function's own contract — what it does, params, returns, errors, invariants — and nothing else. Don't restate the signature; don't document who calls it or where ("used by the signup flow") — that belongs at the call site and goes stale here. Guidance on *when* to call it is fine.
      '';

      programs.claude-code = {
        enable = true;
        package = pkgs.claude-code;
        enableMcpIntegration = true;
        skills = {
          # Source: https://tropes.fyi/tropes-md by ossama.is. The whole skill
          # (frontmatter + catalog) lives in ./_tropes-md.md; import-tree skips
          # _-prefixed files so it isn't picked up as a module.
          "avoid-ai-tropes" = builtins.readFile ./_tropes-md.md;

          # Post-generation cleanup pass — prunes comment/doc bloat to the
          # minimal why. Examples live in the skill file, not in the always-loaded
          # base context. Run manually (/prune-comments [scope]) after generating.
          "prune-comments" = builtins.readFile ./_prune-comments.md;

          "grill-me" = ''
            ---
            name: grill-me
            description: Interview the user relentlessly about a plan or design until reaching shared understanding, resolving each branch of the decision tree. Use when user wants to stress-test a plan, get grilled on their design, or mentions "grill me".
            ---

            Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

            Ask the questions one at a time.

            If a question can be answered by exploring the codebase, explore the codebase instead.
          '';

          "refactor-python" = mkRefactorSkill {
            lang = "Python";
            extra = ''
              - Follow PEP 8 style guidelines for Python code to ensure consistency and readability.
              - Use type hints for function signatures.
              - Prefer dataclasses or Pydantic over raw dicts for structured data.'';
          };

          "refactor-rust" = mkRefactorSkill {
            lang = "Rust";
            extra = ''
              - Follow Rust's official style guidelines (rustfmt) to ensure consistency and readability.
              - Prefer `impl` blocks over standalone functions where it improves API ergonomics.
              - Use the `?` operator for error propagation instead of manual `match`/`unwrap`.
              - Prefer iterators and combinators over manual loops where readability isn't hurt.'';
          };

          "refactor-typescript" = mkRefactorSkill {
            lang = "TypeScript";
            extra = ''
              - Follow a consistent coding style and use a linter (e.g. ESLint) to enforce it.
              - Avoid using the `any` type, and prefer more specific types to improve type safety and readability.
              - Use async/await for asynchronous code to improve readability and maintainability, and avoid callback hell.
              - Prefer `interface` over `type` for object shapes (better error messages, extendability).
              - Use `const` assertions and discriminated unions over enums.
              - Always prefer erasableSyntaxOnly-compatible TypeScript — avoid `enum`, `namespace`, parameter properties, and other non-erasable syntax.'';
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

          "handoff" = ''
            ---
            name: handoff
            description: Hand off the implementation of one or a few specific items from a longer list to a fresh agent, packaging only the context those items need.
            argument-hint: Which item(s) from the list to hand off?
            allowed-tools: Read, Write, Grep, Glob, Bash(mktemp:*)
            disable-model-invocation: true
            ---
            Write a focused handoff document so a fresh agent can implement only the selected item(s) from a longer list, with no dependence on the rest of this conversation.

            First, identify which item(s) to hand off. If the user passed arguments, use them to select (by number, by name, or by paraphrase — match generously). If it's ambiguous which item they mean, ask before writing.

            Then write the doc covering, for the selected item(s) only:

            - The suggestion itself, stated precisely (not the list around it).
            - Why it was suggested — the problem it solves or the rationale, so the next agent understands intent rather than just the instruction.
            - The concrete files, functions, components, or locations involved.
            - Any decisions, constraints, or gotchas about this item that surfaced in the conversation (e.g. "must stay backwards-compatible", "don't touch the legacy adapter").
            - A clear definition of done / acceptance criteria.

            Deliberately leave out the other items in the list and unrelated conversation context — the entire point is a narrow, self-contained brief. If a sibling item is a genuine dependency, mention it in one line as context, don't fold its work in.

            Save the doc to a path produced by `mktemp -t handoff-XXXXXX.md` (read the file before you write to it).

            Suggest the skills, if any, the next session should use to do the work.

            Do not duplicate content already captured in other artifacts (PRDs, plans, issues, tickets, commits, diffs). Reference them by path or URL instead.
          '';

          "handoff-all" = ''
            ---
            name: handoff-all
            description: Split an entire list of suggestions into several standalone implementation plans, grouping related items so each plan can be handed to its own fresh agent.
            argument-hint: Optional — how to group (e.g. "by file", "one plan per concern")
            allowed-tools: Read, Write, Grep, Glob, Bash(mktemp:*)
            disable-model-invocation: true
            ---
            Take the entire list of items from the conversation and split it into several standalone plans, grouping items that make sense to implement together, so each plan can be handed to its own fresh agent.

            First, identify the full list. Then group it. Cluster items that belong together by:

            - Shared surface — same file, module, component, or subsystem.
            - Shared concern — e.g. performance, security, accessibility, tests, types, docs.
            - Dependency or ordering — items that must be done together or in sequence belong in the same plan.

            Keep each group independently actionable: a fresh agent should be able to pick up one plan without needing the others or this conversation. If two items must ship together, put them in the same plan. Avoid one giant catch-all plan, and avoid scattering into trivial single-item plans unless an item is genuinely standalone. Name each group by its theme.

            For each group, write one standalone plan to its own path produced by `mktemp -t handoff-plan-XXXXXX.md` (read each file before you write to it). Each plan contains, for every item in it:

            - The suggestion itself, stated precisely.
            - Why it was suggested — the problem it solves or the rationale.
            - The concrete files, functions, components, or locations involved.
            - Any decisions, constraints, or gotchas about it that surfaced in the conversation.
            - A clear definition of done / acceptance criteria.

            Within a plan, note any ordering between its items if it matters. Across plans, if one plan depends on another, mention it in a single line — don't fold the other plan's work in.

            Suggest the skills, if any, each plan's session should use.

            Do not duplicate content already captured in other artifacts (PRDs, plans, issues, tickets, commits, diffs). Reference them by path or URL instead.

            Finish by printing a short index to the user: one line per plan giving its theme, the items it covers, and its file path, so they can see the grouping at a glance and dispatch the plans.

            If the user passed arguments, treat them as steering for the grouping (e.g. "group by file", "keep the backend ones together", "one plan per concern") and follow that preference.
          '';
        };

        settings = {
          voiceEnabled = true;
          useAutoModeDuringPlan = true;
          skipAutoPermissionPrompt = true;
          env = {
            CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
          };
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
