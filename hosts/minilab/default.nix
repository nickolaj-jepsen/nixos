{
  config = {
    fireproof = {
      hostname = "minilab";
      username = "nickolaj";
      desktop = {
        enable = true;
        chromium.enable = false;
        zed.enable = false;
      };
      dev = {
        enable = true;
        intellij.enable = false;
        clickhouse.enable = false;
        playwright.enable = false;
      };
    };

    facter.reportPath = ./facter.json;
  };

  imports = [
    ./disk-configuration.nix
    ./monitors.nix
  ];
}
