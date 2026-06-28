# Handy speech-to-text on darwin: a Homebrew cask. No declarative HM half — it's
# a Mac-only app with local state.
{
  flake.modules.darwin.handy = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      homebrew.casks = ["handy"];
    };
  };
}
