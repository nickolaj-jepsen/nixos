{
  inputs,
  config,
  ...
}: let
  inherit (inputs.nixpkgs) lib;
  fpLib = import ../lib {inherit lib;};
  system = "x86_64-linux";

  # The installer ISO, built directly (not through the host resolver — it isn't a
  # host). `name == null` is the generic image; a host name pulls in the
  # source-baking + install leaves and stamps the host it installs onto.
  #
  # Module list is deliberately slim: the upstream installation-cd plus only the
  # two dendritic leaves the ISO actually benefits from — `fireproof-options`
  # (option decls) and `nix` (its substituters, so a desktop install pulls
  # niri/dms from the caches instead of compiling on the live USB). The lone
  # `fireproof.username` fact feeds that nix leaf's trusted-users.
  build = name:
    inputs.nixpkgs.lib.nixosSystem {
      specialArgs = {inherit inputs fpLib;};
      modules =
        [
          {nixpkgs.hostPlatform = system;}
          {fireproof.username = "nixos";}
          config.flake.modules.nixos.fireproof-options
          config.flake.modules.nixos.nix
          ./options.nix
          ./iso.nix
        ]
        ++ lib.optionals (name != null) [
          ./bake.nix
          ./bootstrap-install.nix
          {installer.targetHost = name;}
        ];
    };
in {
  config.flake.nixosConfigurations =
    {bootstrap = build null;}
    // lib.listToAttrs (
      map (n: lib.nameValuePair "bootstrap-${n}" (build n)) config.flake.hostNames
    );
}
