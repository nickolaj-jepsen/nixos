# phone-vm — NixOS on the Pixel 8 Pro, booted by the Podroid fork's AVF
# disk-image mode (modules/system/avf.nix). Stripped to the boot path while
# the PoC proves it; dev and Tailscale come back once it boots.
{
  class = "nixos";

  shared = {
    fireproof.hostname = "phone-vm";
    fireproof.avf.enable = true;
    fireproof.tailscale.enable = false;
  };

  nixos = {
    nixpkgs.hostPlatform = "aarch64-linux";
    # A full-width build inside the VM freezes the whole phone; stay slow but usable.
    nix.settings = {
      max-jobs = 1;
      cores = 2;
    };
  };
}
