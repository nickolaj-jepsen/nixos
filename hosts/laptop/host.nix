{
  shared = {
    fireproof.hostname = "laptop";
    fireproof.trusted = true;

    fireproof.desktop.enable = true;
    fireproof.dev.enable = true;
    fireproof.dev.agent-hub.remotes = {
      desktop = {};
      minilab = {};
    };
    fireproof.work.enable = true;
    fireproof.hardware.laptop = true;
  };

  homeManager = {lib, ...}: {
    programs.ssh.settings."bastion.ao" = {
      ProxyJump = lib.mkForce "homelab";
    };
  };
}
