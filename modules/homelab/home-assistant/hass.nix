{
  pkgs,
  pkgsUnstable,
  config,
  lib,
  ...
}: let
  homeAssistantPort = 8123;
in {
  config = lib.mkIf config.fireproof.homelab.enable {
    age.secrets.hassSecrets = {
      rekeyFile = ../../../secrets/hosts/homelab/hass.yaml.age;
      path = "${config.services.home-assistant.configDir}/secrets.yaml";
      mode = "400";
      owner = "hass";
      group = "hass";
    };

    services.restic.backups.homelab = {
      paths = [config.services.home-assistant.configDir];
    };

    services.nginx.virtualHosts."ha.nickolaj.com" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://localhost:${toString homeAssistantPort}";
        proxyWebsockets = true;
      };
    };

    services.home-assistant = {
      enable = true;
      package = pkgsUnstable.home-assistant;
      customComponents = with pkgsUnstable.home-assistant-custom-components; [
        adaptive_lighting
        sleep_as_android_mqtt
        pkgs.homeAssistantCustomComponents.bambu_lab
        pkgs.homeAssistantCustomComponents.switch_manager
        pkgs.homeAssistantCustomComponents.zwift
      ];
      extraComponents = [
        "analytics"
        "default_config"
        "isal"
        "shopping_list"
        "nextcloud"
        "met"
        "mqtt"
        "ffmpeg"
        "esphome"
        "google"
        "spotify"
        "unifi"
        "upnp"
        "homeassistant_hardware"
        "mcp_server"
        "mcp"
      ];
      config = {
        homeassistant = {
          name = "Home";
          latitude = "!secret latitude";
          longitude = "!secret longitude";
          elevation = "!secret elevation";
          unit_system = "metric";
          time_zone = "Europe/Copenhagen";
          external_url = "https://ha.nickolaj.com";
        };
        frontend = {
          themes = "!include_dir_merge_named themes";
        };
        http = {
          server_port = homeAssistantPort;
          use_x_forwarded_for = true;
          trusted_proxies = [
            "127.0.0.1"
            "::1"
          ];
        };
        sensor = [
          {
            platform = "zwift";
            username = "!secret zwift_username";
            password = "!secret zwift_password";
          }
        ];

        automation = "!include automations.yaml";
        script = "!include scripts.yaml";
        scene = "!include scenes.yaml";
      };
    };
  };
}
