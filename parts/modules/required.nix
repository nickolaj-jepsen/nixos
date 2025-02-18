{
  imports = [
    ./base/nix.nix
    ./base/networking.nix
    ./base/security.nix
    ./base/secrets.nix
    ./base/boot.nix
    ./base/ssh.nix
    ./base/default-apps.nix
    ./dev/just.nix
    ./hardware/usb.nix
  ];
}
