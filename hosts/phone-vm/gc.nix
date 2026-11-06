# Keep the running generation and one to roll back to, pruned by the pocketnix agent
# after each boot rather than by the weekly GC.
{
  nixos = {lib, ...}: {
    boot.loader.systemd-boot.configurationLimit = 2;

    # The agent prunes after each boot (and its own switches) and collects; its default of 0
    # would leave no rollback once the new generation has booted.
    pocketnix.guest.updates.keepGenerations = 1;

    # The count above is the limit; an age limit would drop the fallback.
    nix.gc.options = lib.mkForce "";
  };
}
