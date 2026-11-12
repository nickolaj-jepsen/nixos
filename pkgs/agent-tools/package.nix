# The agent plugins' sources, checked: the harness-free cores type-check and pass
# their own tests here. Each agent's leaf builds its half from `$out/plugins/<name>`
# against the agent that runs it.
{
  lib,
  buildNpmPackage,
  importNpmLock,
}: let
  # Only what the check reads, so a skill, demo or README edit doesn't rebuild the mods.
  src = lib.fileset.toSource {
    root = ../../agent-tools;
    fileset = lib.fileset.unions [
      ../../agent-tools/package.json
      ../../agent-tools/package-lock.json
      ../../agent-tools/tsconfig.json
      ../../agent-tools/vitest.config.ts
      ../../agent-tools/plugins
    ];
  };
in
  buildNpmPackage {
    pname = "agent-tools";
    version = "0";
    inherit src;
    npmDeps = importNpmLock {npmRoot = src;};
    inherit (importNpmLock) npmConfigHook;
    dontNpmBuild = true;
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      npm run typecheck
      npm test
      runHook postCheck
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r plugins $out/
      runHook postInstall
    '';
  }
