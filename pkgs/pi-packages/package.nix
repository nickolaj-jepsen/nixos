# The third-party packages the pi leaf loads: one npm tree, so pi loads them
# as local paths instead of running `npm install` at startup. Roster and pins
# live in ./package.json; the update bot bumps them and regenerates the lock.
{
  buildNpmPackage,
  importNpmLock,
  lib,
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
      # Lists the build-time tarball store paths, which would drag every
      # package source into the runtime closure.
      rm -f $out/node_modules/.package-lock.json
      runHook postInstall
    '';
    # settings.packages points at these, one local path each.
    passthru.packageNames = builtins.attrNames packageJson.dependencies;
  }
