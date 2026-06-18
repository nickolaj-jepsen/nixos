# work's host-specific home-manager bits (wired via targets.work.homeModules in
# hosts/default.nix). Merges into the user's HM eval alongside the selected leaves.
{lib, ...}: {
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
}
