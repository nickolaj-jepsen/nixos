# The third-party packages the pi leaf loads: one npm tree, so pi loads them
# as local paths instead of running `npm install` at startup. Roster and pins
# live in ./package.json; the update bot bumps them and regenerates the lock.
{
  buildNpmPackage,
  importNpmLock,
  lib,
  # pi-background-tasks paints its selection band with its own hardcoded colors;
  # callers pass `config.fireproof.theme.colors` so it stays on the palette.
  themeColors ? {
    uiAlt = "403E3C";
    fg = "DAD8CE";
    blue = "4385BE";
  },
}: let
  packageJson = lib.importJSON ./package.json;

  # ANSI "r;g;b" from a palette hex, matching the escapes the extension writes.
  rgb = name: let
    # Nix has no hex parser; TOML's 0x integer literal is the shortest way in.
    value = (builtins.fromTOML "v = 0x${themeColors.${name}}").v;
    channel = shift: toString (builtins.bitAnd (builtins.div value shift) 255);
  in "${channel 65536};${channel 256};${channel 1}";
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
    # The widget's light-blue band is unreadable once the theme's own fg resets
    # take over inside a selected row (pale on pale). Recolor it to the palette.
    postInstall = ''
      for file in \
        $out/node_modules/pi-background-tasks/dist/src/ui/background-tasks-manager.js \
        $out/node_modules/pi-background-tasks/src/ui/background-tasks-manager.ts; do
        substituteInPlace "$file" \
          --replace-fail '48;2;183;223;255' "48;2;${rgb "uiAlt"}" \
          --replace-fail '38;2;11;70;110' "38;2;${rgb "fg"}" \
          --replace-fail '38;2;83;160;215' "38;2;${rgb "blue"}"
      done
    '';
    # settings.packages points at these, one local path each.
    passthru.packageNames = builtins.attrNames packageJson.dependencies;
  }
