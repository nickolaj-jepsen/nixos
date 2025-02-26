{lib, ...}: {
  fireproof.home-manager.programs.ssh.matchBlocks = {
    "dev.ao" = {
      hostname = "192.168.2.28";
      proxyJump = lib.mkForce null;
    };
    "flex.ao" = {
      hostname = "192.168.2.5";
      proxyJump = lib.mkForce null;
    };
    "bastion.ao" = {
      hostname = "192.168.2.6";
      proxyJump = lib.mkForce null;
    };
    "server" = {
      proxyJump = "bastion.ao";
    };
  };
}
