# OpenAI Codex: the CLI, plus the desktop client. Codex has no app of its own —
# it is a workspace inside the ChatGPT desktop app (`chatgpt`), which is what
# both halves install. Both come from nixpkgs-unstable.
#
# The app is an everyday GUI app, so it gates on desktop.enable with no toggle of
# its own; on the Mac it is the `chatgpt` cask and the nixpkgs build stays off
# (docs/hosts.md "Cross-platform apps").
{
  flake.modules.darwin.codex = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      homebrew.casks = ["chatgpt"];
    };
  };

  flake.modules.homeManager.codex = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkMerge [
      (lib.mkIf config.fireproof.dev.enable {
        home.packages = [pkgs.unstable.codex];
      })
      (lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
        home.packages = [pkgs.unstable.chatgpt];
        # Its own `codex://` links (and the ones Codex prints) land in the app;
        # the managed mimeapps list would otherwise drop the handler.
        xdg.mimeApps.defaultApplications."x-scheme-handler/codex" = "chatgpt.desktop";
      })
    ];
  };
}
