{
  shared = {
    fireproof.hostname = "desktop-wsl";
    fireproof.username = "nickolaj";

    fireproof.dev.enable = true;
    fireproof.work.enable = true;
    fireproof.wsl.enable = true;
  };

  homeManager = {lib, ...}: {
    programs.ssh.settings."bastion.ao" = {
      HostName = "62.199.221.53";
      ProxyJump = lib.mkForce null;
    };
  };
}
