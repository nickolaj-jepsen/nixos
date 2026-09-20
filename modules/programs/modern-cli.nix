# Modern CLI replacements (fd/dust). Enabled everywhere — they pair with the
# existing fzf/zoxide/ripgrep stack. fd is the gitignore-aware backend used by
# fzf.fish.
{
  flake.modules.homeManager.modern-cli = {pkgs, ...}: {
    programs.fd.enable = true;

    # No home-manager module for dust; ship the binary directly.
    home.packages = [pkgs.dust];
  };
}
