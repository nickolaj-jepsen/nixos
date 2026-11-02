# The base's daemon tuning suits a desktop; here the guest's CPU and RAM are the phone's, and a
# big copy at that width can freeze the whole device.
{
  nixos = {lib, ...}: {
    nix.settings.max-substitution-jobs = lib.mkForce 2;
    nix.daemonCPUSchedPolicy = lib.mkForce "idle";
    nix.daemonIOSchedClass = lib.mkForce "idle";
  };
}
