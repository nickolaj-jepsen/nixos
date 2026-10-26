# phone-vm — NixOS on the Pixel 8 Pro, a lean headless dev env run by the
# pocketnix app (modules/system/pocketnix.nix). Bootstrap per docs/hosts.md.
{
  class = "nixos";

  shared = {
    fireproof.hostname = "phone-vm";
    fireproof.pocketnix.enable = true;

    fireproof.dev.enable = true;
    fireproof.dev.intellij.enable = false;
    fireproof.dev.clickhouse.enable = false;
    fireproof.dev.opencode.enable = false;
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
