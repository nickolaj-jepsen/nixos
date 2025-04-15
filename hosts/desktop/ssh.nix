{lib, ...}: {
  fireproof.home-manager.programs.ssh.matchBlocks = {
    "bastion.ao" = {
      hostname = "62.199.221.53";
      proxyJump = lib.mkForce null;
    };
  };
}
