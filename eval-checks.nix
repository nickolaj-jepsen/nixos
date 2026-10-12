# Eval-only checks: forced in CI's `check` job (ci-build.sh over checks.x86_64-linux),
# which update triage maps failures back from.
#
# flake-eval: what `nix flake check` evaluated beyond the hosts the build matrix
# already covers (bootstrap ISOs, packages, the devshell), so CI evaluates each
# real host once instead of twice.
#
# host-invariants: what every real host must keep. The update PR automerges, so
# an input whose module adds a binary cache or widens trust would otherwise ship
# unseen; the toggle asserts catch a refactor that quietly drops a feature.
{
  config,
  lib,
  ...
}: let
  inherit (config) flake;
  bootstrap = lib.filterAttrs (n: _: lib.hasPrefix "bootstrap" n) flake.nixosConfigurations;
  hosts = lib.filterAttrs (n: _: !lib.hasPrefix "bootstrap" n) flake.nixosConfigurations;

  # Adding a cache on purpose means adding it here too (keys mirror modules/base/nix.nix).
  allowedSubstituters = c: [
    "https://cache.nixos.org/"
    "https://attic.${c.fireproof.homelab.domain}/nixos"
    "https://nix-community.cachix.org"
    "https://cache.nixos-cuda.org"
  ];
  allowedKeys = [
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    "nixos:yGPW0JSJw+piW/f/7XwmwMdnzz2mUEA8b4Zcco80wkI="
    "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
  ];

  invariants = name: host: let
    c = host.config;
    s = c.nix.settings;
    ssh = c.services.openssh.settings;
    ok = cond: msg: lib.assertMsg cond "${name}: ${msg}";
    extra = allowed: xs: lib.concatStringsSep " " (lib.subtractLists allowed xs);
    subs = extra (allowedSubstituters c) (s.substituters ++ s.trusted-substituters);
    keys = extra allowedKeys s.trusted-public-keys;
    users = extra ["root" c.fireproof.username] s.trusted-users;
  in
    ok (subs == "") "unexpected substituter(s): ${subs} (allow in eval-checks.nix if intended)"
    && ok (keys == "") "unexpected trusted-public-key(s): ${keys} (allow in eval-checks.nix if intended)"
    && ok (users == "") "trusted-users widened: ${users}"
    && ok (!c.services.openssh.enable || !(ssh.PasswordAuthentication || ssh.KbdInteractiveAuthentication))
    "sshd accepts passwords"
    && ok (ssh.PermitRootLogin != "yes") "sshd permits root password login"
    && ok c.networking.firewall.enable "firewall is off"
    && ok (c.fireproof.desktop.enable -> c.programs.niri.enable) "desktop.enable without niri"
    && ok (c.fireproof.homelab.enable -> c.services.restic.backups != {}) "homelab.enable without restic backups";
in {
  perSystem = {
    config,
    pkgs,
    system,
    ...
  }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.flake-eval = pkgs.writeText "flake-eval" (builtins.unsafeDiscardStringContext (lib.concatLines (
        lib.mapAttrsToList (n: c: "${n} ${c.config.system.build.toplevel.drvPath}") bootstrap
        ++ lib.mapAttrsToList (n: p: "packages.${n} ${p.drvPath}") config.packages
        ++ lib.mapAttrsToList (n: d: "devShells.${n} ${d.drvPath}") config.devShells
      )));
      checks.host-invariants = assert lib.all (n: invariants n hosts.${n}) (lib.attrNames hosts); pkgs.emptyFile;
    };
}
