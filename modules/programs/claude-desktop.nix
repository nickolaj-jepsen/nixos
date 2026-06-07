# Enabled when: desktop
# Claude Desktop, packaged via github:aaddrick/claude-desktop-debian (overlay
# wired up in overlays/default.nix). The -fhs variant is used so bundled MCP
# servers can run inside an FHS environment.
{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf config.fireproof.desktop.enable {
    fireproof.home-manager.home.packages = [
      pkgs.claude-desktop-fhs
    ];
  };
}
