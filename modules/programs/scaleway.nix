# scw + the shared Scaleway config. Home-manager half only: the config holds both
# API key pairs, so it is sealed (secrets/scaleway/config.age) and placed as a
# read-only symlink into /run/agenix, where `scw config set` cannot rewrite it.
#
# Profiles (org 08c3f6f1-091f-4f4f-8d29-b382b469f4b8, region nl-ams, zone nl-ams-1):
#   ao-dev   → b2c-devenv     active by default, write access
#   ao-prod  → b2c-production same user key as ao-dev, so NOT read-only
#
# `ao-prod` is safe only by discipline: `-p ao-prod` is what makes a production
# command deliberate, which is why both agents ask on anything naming it (see the
# bash rules in modules/programs/pi/default.nix and claude-code/default.nix).
# Since the key carries AllProductsFullAccess, a production write is one
# unattended command away. A genuinely read-only profile needs an IAM application
# with AllProductsReadOnly scoped to b2c-production; once one exists, swap the two
# key lines in the blob, `just secret-rekey`, rebuild.
#
# default_project_id is not a read scope: `scw <product> list` enumerates the whole
# organization (verified: 16 b2c-production servers show up under ao-dev) and only
# filters when you pass project-id= yourself. So the destructive-verb asks, not the
# profile name, are what stand between an agent and a UUID-targeted prod change.
#
# Rotate: edit the sealed YAML (`just secret-edit secrets/scaleway/config.age`),
# then `just secret-rekey` and `just switch`.
{
  flake.modules.homeManager.scaleway = {
    config,
    lib,
    pkgs,
    ...
  }: let
    inherit (config.home) homeDirectory;
  in {
    config = lib.mkIf config.fireproof.dev.scaleway.enable {
      home.packages = [pkgs.scaleway-cli];

      age.secrets.scw-config = {
        rekeyFile = ../../secrets/scaleway/config.age;
        path = "${homeDirectory}/.config/scw/config.yaml";
        # 0400 so `scw config set` / `config profile activate` fail instead of
        # silently repointing a profile's credentials or the active profile.
        mode = "0400";
      };
    };
  };
}
