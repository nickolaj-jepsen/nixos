{lib, ...}: {
  fireproof.home-manager.programs.ssh.settings = {
    "dev.ao" = {
      ProxyJump = lib.mkForce null;
    };
    "flex.ao" = {
      ProxyJump = lib.mkForce null;
    };
    "bastion.ao" = {
      HostName = "192.168.2.6";
    };
    "clickhouse.ao" = {
      ProxyJump = "bastion.ao";
    };
    homelab = {
      ProxyJump = "bastion.ao";
    };
  };
}
