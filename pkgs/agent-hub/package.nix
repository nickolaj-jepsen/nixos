# `agent-hub daemon`: the desktop hub for live coding-agent sessions. Config is
# ~/.config/agent-hub/config.json (written by modules/programs/agent-hub.nix).
# The build runs its protocol tests against a real daemon.
{
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
    nativeCheckInputs = [python3Packages.unittestCheckHook];
    unittestFlags = ["-s" "tests" "-p" "test_*.py"];

    meta = {
      inherit (project) description;
      mainProgram = "agent-hub";
      # Watches the session registry with inotify.
      platforms = lib.platforms.linux;
    };
  }
