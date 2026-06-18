# phone — a personal Android device running nix-on-droid (aarch64, no systemd).
# class = "droid" routes it through buildDroid (a nix-on-droid eval, no NixOS
# eval) into flake.nixOnDroidConfigurations.phone. The homeManager leaves run in
# nix-on-droid's embedded home-manager, so the phone reuses the same fish/neovim/
# git/claude-code/dev CLI as the rest of the fleet — dev-ao, but on Android.
#
# Lean & personal: dev tooling on, but the work/GUI-bound dev extras off, so the
# phone declares no agenix secrets (nothing to decrypt on-device). Build/activate
# ON the device:  nix-on-droid switch --flake ~/nixos#phone
{
  class = "droid";

  shared = {
    fireproof.hostname = "phone";
    fireproof.username = "nickolaj";

    fireproof.dev.enable = true;
    # Work k8s/grafana-mcp + GUI/browser-bound extras have no backend on a personal
    # phone; off keeps the closure lean and the host free of rekeyed secrets.
    fireproof.dev.k8s.enable = false;
    fireproof.dev.mcp.enable = false;
    fireproof.dev.clickhouse.enable = false;
    fireproof.dev.playwright.enable = false;
    fireproof.dev.intellij.enable = false;
  };

  # The fleet's claude-code overlay pins an x86-64 prebuilt binary (overlayAttrs
  # are computed on the x86 build host and applied verbatim to the aarch64 pkgs),
  # so pkgs.claude-code is a wrong-arch ELF here. Use the stock multi-arch
  # nixpkgs-unstable build instead — claude-code is the phone's whole point.
  homeManager = {
    pkgs,
    lib,
    ...
  }: {
    programs.claude-code.package = lib.mkForce pkgs.unstable.claude-code;
  };

  # nix-on-droid system eval (its own option set — no fireproof.* here).
  droid = {pkgs, ...}: {
    user.shell = "${pkgs.fish}/bin/fish";

    time.timeZone = "Europe/Copenhagen";

    # Flakes enabled so `nix-on-droid switch --flake` works on-device.
    nix.extraOptions = ''
      experimental-features = nix-command flakes
    '';

    # Read the nix-on-droid changelog before bumping (enum maxes at 24.05 on master).
    system.stateVersion = "24.05";
  };
}
