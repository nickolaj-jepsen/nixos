{
  shared = {
    fireproof.hostname = "minilab";
    fireproof.trusted = true;

    # A headless agent machine: no desktop, to leave the eMMC room for agents' work.
    fireproof.dev.enable = true;
    fireproof.dev.agent-hub.viewers = ["desktop" "laptop"];
    fireproof.dev.intellij.enable = false;
    fireproof.dev.clickhouse.enable = false;
  };
}
