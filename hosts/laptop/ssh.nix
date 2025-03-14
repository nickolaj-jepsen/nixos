{lib, ...}: {
  fireproof.home-manager.programs.ssh.matchBlocks = {
    "dev.ao" = {
      proxyJump = lib.mkForce "server";
    };
    "bastion.ao" = {
      proxyJump = lib.mkForce "server";
    };
  };
}
