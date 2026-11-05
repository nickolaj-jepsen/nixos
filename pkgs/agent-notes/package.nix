# `agent-notes`: where a checkout's notes live. The store is per checkout, keyed
# by a hash of the main worktree's path, and each checkout sees it through
# `.agents/{store,tmp}`. Init runs from a git hook, so it is quiet and always
# succeeds; the tests drive it against throwaway repositories.
{
  git,
  lib,
  python3Packages,
}: let
  inherit ((builtins.fromTOML (builtins.readFile ./pyproject.toml))) project;
in
  python3Packages.buildPythonApplication {
    pname = "agent-notes";
    inherit (project) version;
    pyproject = true;
    src = ./.;

    build-system = [python3Packages.setuptools];
    nativeCheckInputs = [python3Packages.unittestCheckHook git];
    unittestFlags = ["-s" "tests" "-p" "test_*.py"];

    meta = {
      inherit (project) description;
      mainProgram = "agent-notes";
      platforms = lib.platforms.unix;
    };
  }
