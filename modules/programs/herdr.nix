# Herdr: a desktop app for terminals and coding agents, plus herdr-core (the
# background program they actually run in; `hc` is its CLI). Neither is in
# nixpkgs 26.05, so both come from unstable. They are built here rather than by
# Herdr's installer, which means Herdr's own updater stays out of it — the
# nixpkgs build says so in Settings → Updates. herdr-desktop carries its
# herdr-core's store path, and herdr-core on PATH keeps `hc` beside it for
# agents in any terminal.
{
  flake.modules.homeManager.herdr = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      home.packages = [
        pkgs.unstable.herdr-desktop
        pkgs.unstable.herdr-core
      ];
    };
  };
}
