# work's host card.
{
  aspects = ["workstation" "physical" "nvidia" "chromium" "intellij" "clickhouse" "claude-work" "networkd"];

  shared = {
    fireproof.hostname = "work";
    fireproof.username = "nickolaj";
    fireproof.monitors = import ./_monitors.nix;
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
