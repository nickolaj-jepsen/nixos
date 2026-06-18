{
  shared = {
    fireproof.hostname = "work";
    fireproof.username = "nickolaj";

    fireproof.desktop.enable = true;
    fireproof.dev.enable = true;
    fireproof.work.enable = true;
    fireproof.hardware.nvidia.enable = true;
    fireproof.claude-code.work.enable = true;
    fireproof.networkd.enable = true;
  };

  homeManager = {lib, ...}: {
    programs.firefox.profiles.default.settings."browser.startup.homepage" =
      lib.mkForce "https://glance.nickolaj.com/work";

    programs.ssh.settings = {
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
  };
}
