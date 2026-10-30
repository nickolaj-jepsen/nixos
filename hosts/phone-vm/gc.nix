# The phone's disk holds about two closures: keep the running generation and one
# to roll back to, pruned at every switch rather than by the weekly GC. Pruned
# closures are then free for nix.nix's min-free collection when a copy runs low.
{
  nixos = {
    config,
    lib,
    ...
  }: {
    boot.loader.systemd-boot.configurationLimit = 2;

    # The switch sets the profile before activating, so the new generation is one of the two.
    system.activationScripts.prune-generations = ''
      ${config.nix.package}/bin/nix-env -p /nix/var/nix/profiles/system --delete-generations +2
    '';
    # The count above is the limit; an age limit would drop the fallback.
    nix.gc.options = lib.mkForce "";
  };
}
