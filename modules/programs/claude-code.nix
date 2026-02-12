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
        - Unless otherwise instructed, for git, use conventional commit for commit-messages, with a max line-width of 72 chars, keep the commit as concise as possible, and don't add a "body" if it isn't necessary
      '';

      programs.claude-code = {
        enable = true;

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
