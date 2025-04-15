{lib, ...}: {
  fireproof.home-manager.programs.ssh.matchBlocks = {
    "dev.ao" = {
      proxyJump = lib.mkForce null;
    };
    "flex.ao" = {
      proxyJump = lib.mkForce null;
    };
    "bastion.ao" = {
      hostname = "192.168.2.6";
    };
    "clickhouse.ao" = {
      proxyJump = "bastion.ao";
    };
    "server" = {
      proxyJump = "bastion.ao";
    };
  };
}
