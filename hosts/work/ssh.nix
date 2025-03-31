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
    "clickhouse.ao" = {
      hostname = "51.158.205.48";
      proxyJump = "bastion.ao";
    };
    "server" = {
      proxyJump = "bastion.ao";
    };
  };
}
