# The home directory layout: docs/home-layout.md.
{fpLib, ...}: {
  flake.modules.homeManager.home-layout = {
    config,
    lib,
    pkgs,
    ...
  }: let
    inherit (config.fireproof) desktop dev;
    path = fpLib.homePath config;
    created =
      lib.optionals dev.enable (map path ["dev" "worktrees" "scratch"])
      ++ lib.optionals desktop.enable (with config.xdg.userDirs; [documents download pictures]);
  in {
    config = lib.mkIf (desktop.enable || dev.enable) {
      # Every XDG dir keeps its default name so apps agree on it; only `created` gets made.
      # Set on darwin too, where nothing reads it but fpLib.homeRoots.
      xdg.userDirs = {
        enable = pkgs.stdenv.isLinux;
        projects = path "dev";
        # Apps read user-dirs.dirs; the XDG_*_DIR exports are the pre-26.05 default.
        setSessionVariables = false;
      };

      home.activation.homeLayout = lib.hm.dag.entryAfter ["linkGeneration"] (
        lib.concatMapStringsSep "\n" (dir: ''run mkdir -p $VERBOSE_ARG "${dir}"'') created
      );

      # wt's root; unset, it is ~/worktrees.
      home.sessionVariables = lib.mkIf dev.enable {
        WT_WORKTREE_ROOT = path "worktrees";
      };
    };
  };
}
