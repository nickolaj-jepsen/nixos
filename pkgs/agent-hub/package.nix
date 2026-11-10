# `agent-hub daemon`: the hub for live coding-agent sessions. Config is
# ~/.config/agent-hub/config.json (written by modules/programs/agent-hub.nix).
# The build runs its protocol tests against a real daemon.
{
  git,
  lib,
  python3Packages,
}: let
  inherit ((builtins.fromTOML (builtins.readFile ./pyproject.toml))) project;
in
  python3Packages.buildPythonApplication {
    pname = "agent-hub";
    inherit (project) version;
    pyproject = true;
    src = ./.;

    build-system = [python3Packages.setuptools];
    nativeCheckInputs = [python3Packages.unittestCheckHook git];
    unittestFlags = ["-s" "tests" "-p" "test_*.py"];

    meta = {
      inherit (project) description;
      mainProgram = "agent-hub";
      platforms = lib.platforms.linux ++ lib.platforms.darwin;
    };
  }
