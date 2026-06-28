# Claude desktop app on darwin: a Homebrew cask. Account-synced, so there's no
# declarative HM half to manage. (claude-code, the CLI, is a separate leaf.)
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
}
