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
      hostname = "51.158.205.48";
      proxyJump = "bastion.ao";
    };
    "server" = {
      proxyJump = "bastion.ao";
    };
  };
}
