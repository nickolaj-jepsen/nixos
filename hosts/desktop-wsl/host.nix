{
  shared = {
    fireproof.hostname = "desktop-wsl";

    fireproof.dev.enable = true;
    fireproof.work.enable = true;
    fireproof.wsl.enable = true;
  };

  homeManager = {lib, ...}: {
    programs.ssh.settings."bastion.ao" = {
      ProxyJump = lib.mkForce null;
    };
  };
}
