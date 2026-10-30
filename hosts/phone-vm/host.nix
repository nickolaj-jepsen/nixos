# phone-vm — NixOS on the Pixel 8 Pro, a lean dev env run by the
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
    # Disk is scarce on the phone (~500 MiB together) and these have no use there.
    fireproof.docker.enable = false;
    fireproof.dev.tilt.enable = false;
    fireproof.dev.copilot.enable = false;
    # Not "physical", so zram doesn't cascade on; a dev env in a few GB of guest RAM wants it.
    fireproof.hardware.zram = true;
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
