# `wt`: throwaway git worktrees under ~/worktrees/<repo>, landed into the default branch.
# First-party Python tool: the package carries its own CLI tests, and the runtime
# tools it shells out to are added to PATH by the wrapper.
{
  lib,
  python3Packages,
  makeWrapper,
  git,
  coreutils,
}: let
  inherit ((builtins.fromTOML (builtins.readFile ./pyproject.toml))) project;
  runtime = [git coreutils];
in
  python3Packages.buildPythonApplication {
    pname = "wt";
    inherit (project) version;
    pyproject = true;
    src = ./.;

    build-system = [python3Packages.setuptools];
    # `wt clean`'s checklist picker.
    dependencies = [python3Packages.prompt-toolkit];
    nativeBuildInputs = [makeWrapper];
    nativeCheckInputs = [python3Packages.unittestCheckHook git coreutils];
    unittestFlags = ["-s" "tests" "-p" "test_*.py"];

    # `unittestCheckHook` runs after install; pointing the suite at the installed command makes it
    # test the entry point and wrapper users get, not `python -m wt` from the sources.
    env.WT_BIN = "${placeholder "out"}/bin/wt";

    postFixup = ''
      wrapProgram $out/bin/wt --prefix PATH : ${lib.makeBinPath runtime}
    '';

    meta = {
      inherit (project) description;
      mainProgram = "wt";
      platforms = lib.platforms.unix;
      license = lib.licenses.mit;
    };
  }
