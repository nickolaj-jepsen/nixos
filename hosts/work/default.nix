# Selection (aspects + facts) lives in hosts/default.nix. This file holds only
# work's nixos-specific settings; host-specific HM bits live in ./_home.nix.
_: {
  config = {
    facter.reportPath = ./facter.json;

    # aarch64 emulation so this x86_64 host can cross-build the Raspberry Pi
    # kiosk SD image (~/dev/kiosk). Some derivations run target binaries at
    # build time (e.g. writeShellScript's bash -n), which fails without binfmt.
    boot.binfmt.emulatedSystems = ["aarch64-linux"];
  };
}
