_: {
  options.fireproof.base = {};

  imports = [
    ./boot.nix
    ./hosts.nix
    ./keyd.nix
    ./ld.nix
    ./networking.nix
    ./security.nix
    ./ssh.nix
    ./time.nix
    ./usb.nix
    ./user.nix
    ./yubikey.nix
    ./tailscale.nix
  ];
}
