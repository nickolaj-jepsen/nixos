{inputs, ...}: {
  flake.modules.nixos.paseo = {
    config,
    lib,
    pkgs,
    ...
  }: {
    imports = [inputs.paseo.nixosModules.paseo];

    config = lib.mkIf config.fireproof.dev.paseo.enable {
      services.paseo = {
        enable = true;
        package = pkgs.unstable.paseo;
        # Runs as the login user so agents reuse its CLIs and credentials; state lives in ~/.paseo.
        user = config.fireproof.username;
        group = "users";
        # Left empty on purpose: `settings` rewrites config.json on every start,
        # which would wipe the relay consent `paseo daemon pair --relay` stores there.
      };
    };
  };
}
