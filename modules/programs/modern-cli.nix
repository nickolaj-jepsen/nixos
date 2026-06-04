# Modern CLI replacements (bat/fd/dust). Enabled everywhere — they pair with the
# existing fzf/zoxide/ripgrep stack. fd is the gitignore-aware backend used by
# fzf.fish; bat backs fzf.fish's file previews.
{pkgs, ...}: {
  fireproof.home-manager = {
    programs.bat = {
      enable = true;
      # "ansi" renders via the 16 terminal colors, so the ghostty "fireproof"
      # (Flexoki) palette stays authoritative instead of a bundled theme.
      config.theme = "ansi";
    };

    programs.fd.enable = true;

    # No home-manager module for dust; ship the binary directly.
    home.packages = [pkgs.dust];
  };
}
