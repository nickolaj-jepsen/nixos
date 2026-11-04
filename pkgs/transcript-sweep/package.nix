# `transcript-sweep`: redact secrets out of pi and Claude Code transcripts
# (docs/janitor.md, "Transcripts"). Pure stdlib, so no runtime inputs.
{
  lib,
  python3Packages,
}: let
  inherit ((builtins.fromTOML (builtins.readFile ./pyproject.toml))) project;
in
  python3Packages.buildPythonApplication {
    pname = "transcript-sweep";
    inherit (project) version;
    pyproject = true;
    src = ./.;

    build-system = [python3Packages.setuptools];

    nativeCheckInputs = [python3Packages.unittestCheckHook];
    unittestFlags = ["-s" "tests" "-p" "test_*.py"];

    meta = {
      inherit (project) description;
      mainProgram = "transcript-sweep";
      platforms = lib.platforms.unix;
    };
  }
