# Raycast launcher on darwin: a Homebrew cask. Raycast keeps its own config
# (local DB + cloud sync), so there's no declarative HM half to manage.
{
  flake.modules.darwin.raycast = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.raycast.enable {
      homebrew.casks = ["raycast"];
    };
  };
}
