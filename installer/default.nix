{
  inputs,
  config,
  ...
}: let
  inherit (inputs.nixpkgs) lib;
  system = "x86_64-linux";

  # The installer ISO, built directly (not through the host resolver — it isn't a
  # host). `name == null` is the generic image; a host name pulls in the
  # source-baking + install leaves and stamps the host it installs onto.
  #
  # Module list is deliberately slim: the upstream installation-cd plus only the
  # two dendritic leaves the ISO actually benefits from — `fireproof-options`
  # (option decls) and `nix` (its substituters, so an install pulls from attic
  # instead of compiling on the live USB). `fireproof.username` feeds that leaf's
  # trusted-users; a host-baked ISO also copies the target's dev.llm, the only
  # fact that changes the substituter list (the CUDA cache).
  build = name:
    inputs.nixpkgs.lib.nixosSystem {
      specialArgs = {inherit inputs;};
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
          {fireproof.dev.llm.enable = config.flake.nixosConfigurations.${name}.config.fireproof.dev.llm.enable;}
        ];
    };
in {
  config.flake.nixosConfigurations =
    {bootstrap = build null;}
    // lib.listToAttrs (
      map (n: lib.nameValuePair "bootstrap-${n}" (build n)) config.flake.hostNames
    );
}
