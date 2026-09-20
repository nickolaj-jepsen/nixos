{
  shared = {
    fireproof.hostname = "homelab";

    fireproof.dev.enable = true;
    # headless: skip the heavy editor/agent layers
    fireproof.neovim.full.enable = false;
    fireproof.dev.pi.enable = false;
    fireproof.homelab.enable = true;
    fireproof.networkd.enable = true;
  };
}
