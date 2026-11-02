{
  shared = {
    fireproof.hostname = "homelab";
    fireproof.trusted = true;

    fireproof.dev.enable = true;
    # Only the way in for laptop's links: desktop's and minilab's addresses, as the login config has them.
    fireproof.dev.agent-hub.viewers = ["laptop"];
    fireproof.dev.agent-hub.linkJumps = ["10.0.0.20:22" "10.0.0.7:22"];
    # headless: skip the heavy editor layer and the second agent
    fireproof.neovim.full.enable = false;
    fireproof.dev.pi.enable = true;
    fireproof.homelab.enable = true;
    fireproof.networkd.enable = true;
  };

  # Same headless trim for copilot, which has no fireproof toggle of its own.
  homeManager = {lib, ...}: {
    programs.github-copilot-cli.enable = lib.mkForce false;
  };
}
