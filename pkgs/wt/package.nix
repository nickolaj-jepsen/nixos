# `wt`: git worktrees under ~/worktrees/<repo>, with cleanup, review and landing.
# First-party Python tool: the package carries its own CLI tests, and the runtime
# tools it shells out to are added to PATH by the wrapper.
{
  lib,
  stdenv,
  python3Packages,
  makeWrapper,
  git,
  fzf,
  diffnav,
  coreutils,
  lsof,
}: let
  inherit ((builtins.fromTOML (builtins.readFile ./pyproject.toml))) project;
  runtime = [git fzf diffnav coreutils] ++ lib.optional stdenv.isDarwin lsof;
in
  python3Packages.buildPythonApplication {
    pname = "wt";
    inherit (project) version;
    pyproject = true;
    src = ./.;

    build-system = [python3Packages.setuptools];
    nativeBuildInputs = [makeWrapper];
    nativeCheckInputs = [python3Packages.unittestCheckHook git coreutils];
    unittestFlags = ["-s" "tests" "-p" "test_*.py"];

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
