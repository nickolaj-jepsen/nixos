{lib, ...}: {
  fireproof.home-manager.programs.ssh.settings = {
    "bastion.ao" = {
      HostName = "62.199.221.53";
      ProxyJump = lib.mkForce "homelab";
    };
  };
}
