{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  payload = inputs.bootstrap-payload;

  flakeSrc = pkgs.runCommand "flake-src-${config.installer.targetHost}" {} ''
    mkdir -p $out
    cp -r ${
      lib.cleanSourceWith {
        src = inputs.self;
        # Keep `.git` (post-install `git status` depends on it) and
        # `secrets/` (encrypted; the decrypted host key is delivered
        # separately via the override-input payload). Filter out the
        # noise nixpkgs' `cleanSourceFilter` normally would: editor
        # swap/backup files, build artefacts, OS metadata.
        filter = path: type: let
          base = baseNameOf (toString path);
        in
          base
          != "result"
          && base != ".direnv"
          && !(type == "symlink" && lib.hasPrefix "result-" base)
          && !(lib.hasSuffix "~" base)
          && builtins.match "^\\.sw[a-p]$" base == null
          && builtins.match "^\\..*\\.sw[a-p]$" base == null
          && base != ".DS_Store"
          && base != "Thumbs.db";
      }
    }/. $out/
    chmod -R u+w $out
  '';
in {
  # If `bootstrap-payload` isn't overridden, the empty default has no
  # `id_ed25519` file and `environment.etc` will fail at *build* time with a
  # clear missing-source error. We deliberately don't `pathExists`-assert at
  # eval time so `nix flake check` still succeeds without an override.
  assertions = [
    {
      assertion = config.installer.targetHost != "";
      message = "installer/bake.nix requires installer.targetHost to be set.";
    }
  ];

  environment.etc = {
    "iso-bootstrap/ssh/id_ed25519" = {
      source = "${payload}/id_ed25519";
      mode = "0600";
    };
    "iso-bootstrap/ssh/id_ed25519.pub".source = "${payload}/id_ed25519.pub";
    "iso-bootstrap/target-host".text = config.installer.targetHost;
    "iso-bootstrap/nixos".source = flakeSrc;
  };
}
