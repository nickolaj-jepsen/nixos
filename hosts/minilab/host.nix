# snapcast toggle + its turntable capture live in the co-located snapcast.nix;
# oxcb-media needs only its enable toggle (module defaults suffice).
{
  shared = {
    fireproof.hostname = "minilab";
    fireproof.username = "nickolaj";

    fireproof.desktop.enable = true;
    fireproof.desktop.chromium.enable = false;
    fireproof.desktop.oxcbMedia.enable = true;
    fireproof.dev.enable = true;
    fireproof.dev.intellij.enable = false;
    fireproof.dev.clickhouse.enable = false;
    fireproof.dev.playwright.enable = false;
  };
}
