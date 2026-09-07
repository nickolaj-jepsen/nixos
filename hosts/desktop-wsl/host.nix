{
  shared = {
    fireproof.hostname = "desktop-wsl";

    fireproof.dev.enable = true;
    fireproof.work.enable = true;
    fireproof.wsl.enable = true;

    # The Windows-side Tailscale client already covers this machine; a second
    # tailscaled inside WSL would enrol the same host twice.
    fireproof.tailscale.enable = false;
  };

  homeManager = {lib, ...}: {
    programs.ssh.settings."bastion.ao" = {
      ProxyJump = lib.mkForce null;
    };
  };
}
