# Linear desktop app on darwin: a Homebrew cask. Account-synced, so there's no
# declarative HM half to manage.
{
  flake.modules.darwin.linear = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.linear.enable {
      homebrew.casks = ["linear"];
    };
  };
}
