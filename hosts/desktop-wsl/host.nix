# desktop-wsl's host card.
{
  aspects = ["dev" "work" "wsl" "clickhouse"];

  shared = {
    fireproof.hostname = "desktop-wsl";
    fireproof.username = "nickolaj";
  };

  homeManager = {lib, ...}: {
    programs.ssh.settings."bastion.ao" = {
      HostName = "62.199.221.53";
      ProxyJump = lib.mkForce null;
    };
  };
}
