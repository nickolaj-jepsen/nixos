# Selection (aspects + facts) lives in hosts/default.nix. This file holds only
# desktop's nixos-specific settings; host-specific HM bits live in ./_home.nix.
_: {
  config = {
    fireproof.desktop.snapcast.enable = true;
    programs.steam.enable = true;

    facter.reportPath = ./facter.json;
  };
}
