{...}: {
  services.udisks2.enable = true;
  nix.settings.experimental-features = "nix-command flakes";
}
