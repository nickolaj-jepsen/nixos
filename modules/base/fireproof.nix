{
  config,
  lib,
  ...
}: {
  options.fireproof = {
    hostname = lib.mkOption {
      type = lib.types.str;
      description = "The hostname of the machine";
    };
    username = lib.mkOption {
      type = lib.types.str;
      description = "The primary username for the machine";
    };
    work.enable = lib.mkEnableOption "Enable work-related applications and tools";
    dev = {
      enable = lib.mkEnableOption "Enable development tools and applications";
      intellij.enable = lib.mkOption {
        type = lib.types.bool;
        default = config.fireproof.dev.enable;
        description = "Enable IntelliJ-based IDEs";
      };
      clickhouse.enable = lib.mkOption {
        type = lib.types.bool;
        default = config.fireproof.dev.enable;
        description = "Enable Clickhouse";
      };
      playwright.enable = lib.mkOption {
        type = lib.types.bool;
        default = config.fireproof.dev.enable;
        description = "Enable Playwright";
      };
    };
    hardware = {
      laptop = lib.mkEnableOption "Enable laptop-specific configurations and tools";
      battery = lib.mkOption {
        type = lib.types.bool;
        default = config.fireproof.hardware.laptop;
        description = "Enable battery support (UPower, battery widget, etc.)";
      };
      wifi = lib.mkOption {
        type = lib.types.bool;
        default = config.fireproof.hardware.laptop;
        description = "Enable WiFi support (NetworkManager, wireless tools, etc.)";
      };
      dimmableBacklight = lib.mkOption {
        type = lib.types.bool;
        default = config.fireproof.hardware.laptop;
        description = "Enable dimmable backlight support (brightnessctl, backlight widget, etc.)";
      };
    };
  };
}
