# Bitwarden desktop on darwin: a Homebrew cask. The vault is account-synced, so
# there's no declarative HM half to manage.
{
  flake.modules.darwin.bitwarden = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      homebrew.casks = ["bitwarden"];
    };
  };
}
