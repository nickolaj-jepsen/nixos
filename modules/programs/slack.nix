{
  flake.modules.homeManager.slack = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.work.enable) {
      # darwin installs the cask (below); the nixpkgs build is Linux-only.
      home.packages = lib.optionals pkgs.stdenv.isLinux [
        # Wrapped in-package since slack.desktop execs $out/bin/slack by store
        # path. --disable-gpu frees ~85 MiB of VRAM for the local LLM (llm.nix).
        (pkgs.unstable.slack.overrideAttrs (old: {
          postFixup =
            (old.postFixup or "")
            + ''
              wrapProgram $out/bin/slack --add-flags --disable-gpu
            '';
        }))
      ];
      # Slack self-registers this at launch; declared so the managed mimeapps.list keeps it.
      xdg.mimeApps.defaultApplications = lib.mkIf pkgs.stdenv.isLinux {
        "x-scheme-handler/slack" = "slack.desktop";
      };
    };
  };

  # On darwin the nixpkgs build isn't used; install the Homebrew cask instead.
  flake.modules.darwin.slack = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.work.enable) {
      homebrew.casks = ["slack"];
    };
  };
}
