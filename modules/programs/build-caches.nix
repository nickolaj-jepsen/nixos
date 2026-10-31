# Build caches under ~/.cache, which hosts keep out of /home's snapshots.
{
  flake.modules.homeManager.build-caches = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cache = config.xdg.cacheHome;
    vars = {
      GRADLE_USER_HOME = "${cache}/gradle";
      npm_config_cache = "${cache}/npm";
    };
  in {
    config = lib.mkIf config.fireproof.dev.enable {
      home.sessionVariables = vars;
      # Apps launched from the desktop (IDEs) don't inherit the shell's variables.
      systemd.user.sessionVariables = lib.mkIf pkgs.stdenv.isLinux vars;

      # Intermediate artifacts (deps/, incremental/); final binaries stay in target/.
      home.file.".cargo/config.toml".text = ''
        [build]
        build-dir = "${cache}/cargo-build/{workspace-path-hash}"
      '';
    };
  };
}
