# Included by installer/default.nix only for host-baked variants.
{
  inputs,
  pkgs,
  ...
}: let
  # Use the disko binaries from our locked disko input rather than fetching
  # `github:nix-community/disko/latest` at install time. Saves ~1-2 GB of tmpfs
  # pressure on the live ISO (no duplicate nixpkgs eval, no rebuild of disko).
  disko = inputs.disko.packages.${pkgs.stdenv.hostPlatform.system}.disko;
in {
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "bootstrap-install";
      runtimeInputs = with pkgs; [
        nixos-facter
        nixos-install-tools
        util-linux
        coreutils
        gnused
        gnugrep
        gawk
        shadow
        git
        disko
      ];
      text = builtins.readFile ./bootstrap-install.bash;
    })
  ];
}
