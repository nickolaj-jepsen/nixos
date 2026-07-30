# Account-synced, so there's no declarative settings half. (claude-code, the CLI,
# is a separate leaf.)
{
  flake.modules.darwin.claude-desktop = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      homebrew.casks = ["claude"];
    };
  };

  flake.modules.homeManager.claude-desktop = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
      home.packages = [pkgs.claude-desktop];
    };
  };
}
