# laptop's host-specific home-manager bits (wired via targets.laptop.homeModules
# in hosts/default.nix). Merges into the user's HM eval alongside the selected leaves.
{lib, ...}: {
  programs.ssh.settings."bastion.ao" = {
    HostName = "62.199.221.53";
    ProxyJump = lib.mkForce "homelab";
  };
}
