# The third-party packages the pi leaf loads: one npm tree, so pi loads them
# as local paths instead of running `npm install` at startup. Roster and pins
# live in ./package.json; the update bot bumps them and regenerates the lock.
{
  buildNpmPackage,
  importNpmLock,
  lib,
  pi-coding-agent,
}: let
  packageJson = lib.importJSON ./package.json;
in
  buildNpmPackage {
    pname = "pi-packages";
    version = "0";
    src = ./.;
    npmDeps = importNpmLock {npmRoot = ./.;};
    inherit (importNpmLock) npmConfigHook;
    # pi installs these with --legacy-peer-deps too: the packages it aliases at
    # load (@earendil-works/*, typebox) must not be vendored beside them.
    npmFlags = ["--legacy-peer-deps"];
    # The packages ship their own JS/TS; there is no build at the root.
    dontNpmBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r node_modules $out/
      # Managed-only: read the key at runtime and ignore project settings.
      telemetry="$out/node_modules/@amaster.ai/pi-telemetry"
      patch --fuzz=0 -d "$telemetry" -p1 < ${./pi-telemetry-phoenix.patch}
      # The extension's dynamic import bypasses Pi's static module aliases.
      mkdir -p "$telemetry/node_modules/@earendil-works"
      ln -s ${pi-coding-agent}/lib/node_modules/pi-monorepo "$telemetry/node_modules/@earendil-works/pi-coding-agent"
      # Lists the build-time tarball store paths, which would drag every
      # package source into the runtime closure.
      rm -f $out/node_modules/.package-lock.json
      runHook postInstall
    '';
    # Telemetry loads in the personal launcher only; its Langfuse peers are
    # pinned explicitly because npm installs with --legacy-peer-deps.
    passthru.packageNames = builtins.filter (name:
      name != "@amaster.ai/pi-telemetry" && !lib.hasPrefix "@opentelemetry/" name)
    (builtins.attrNames packageJson.dependencies);
  }
