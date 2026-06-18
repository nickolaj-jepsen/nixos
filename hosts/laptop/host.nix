{
  shared = {
    fireproof.hostname = "laptop";
    fireproof.username = "nickolaj";

    fireproof.desktop.enable = true;
    fireproof.dev.enable = true;
    fireproof.work.enable = true;
    fireproof.hardware.laptop = true;
  };

  homeManager = {lib, ...}: {
    programs.ssh.settings."bastion.ao" = {
      HostName = "62.199.221.53";
      ProxyJump = lib.mkForce "homelab";
    };
  };
}
