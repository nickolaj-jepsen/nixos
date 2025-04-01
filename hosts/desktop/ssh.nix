{lib, ...}: {
  fireproof.home-manager.programs.ssh.matchBlocks = {
    "bastion.ao" = {
      proxyJump = lib.mkForce null;
    };
  };
}
