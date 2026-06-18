{
  aspects = ["workstation" "laptop" "chromium" "intellij" "clickhouse"];

  shared = {
    fireproof.hostname = "laptop";
    fireproof.username = "nickolaj";
  };

  homeManager = {lib, ...}: {
    programs.ssh.settings."bastion.ao" = {
      HostName = "62.199.221.53";
      ProxyJump = lib.mkForce "homelab";
    };
  };
}
