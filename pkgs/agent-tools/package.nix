# The agent plugins' sources, checked: the harness-free cores type-check and pass
# their own tests here, and each pi half type-checks against the pi that runs it (so
# an API change there fails this build). Each agent's leaf builds its half from
# `$out/plugins/<name>` against the agent that runs it.
{
  lib,
  buildNpmPackage,
  importNpmLock,
  pi-coding-agent,
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
    # A pi half imports the pi that runs, never an npm copy that would drift from it: the
    # same links the pi leaf's own tsc gets (mkExtensions in modules/programs/pi/default.nix),
    # made after npm's install would have pruned them.
    preCheck = ''
      mkdir -p node_modules/@earendil-works
      ln -s ${pi-coding-agent}/lib/node_modules/pi-monorepo node_modules/@earendil-works/pi-coding-agent
      for dep in ${pi-coding-agent}/lib/node_modules/pi-monorepo/node_modules/@earendil-works/*; do
        ln -s "$dep" node_modules/@earendil-works/
      done
    '';
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
