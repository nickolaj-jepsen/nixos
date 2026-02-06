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
        (pkgs.buildHomeAssistantComponent rec {
          owner = "greghesp";
          domain = "bambu_lab";
          version = "v2.2.20";
          src = pkgs.fetchFromGitHub {
            inherit owner;
            repo = "ha-bambulab";
            rev = version;
            hash = "sha256-lKKfPWWcri2OUM9nkdY2iltvIaoFhnUP4HGBGDUnEww=";
          };
          propagatedBuildInputs = with pkgs.python313.pkgs; [
            beautifulsoup4
          ];
        })
        (pkgs.buildHomeAssistantComponent rec {
          owner = "Sian-Lee-SA";
          domain = "switch_manager";
          version = "v2.0.4b";
          src = pkgs.fetchFromGitHub {
            inherit owner;
            repo = "Home-Assistant-Switch-Manager";
            rev = version;
            hash = "sha256-W9xO3JjnRKHk/dlXMA6y5nEJl/KsGzPvJoumGw+nohw=";
          };
        })
        (pkgs.buildHomeAssistantComponent rec {
          owner = "snicker";
          domain = "zwift";
          version = "v3.3.5";
          src = pkgs.fetchFromGitHub {
            inherit owner;
            repo = "zwift_hass";
            rev = version;
            hash = "sha256-+lJ6Otp8lT+xVtjiQLSQrqT5cVinRTRPTzS+HB1AxB0=";
          };
          propagatedBuildInputs = [
            (pkgs.python313.pkgs.buildPythonPackage {
              pname = "zwift-client";
              version = "0.2.0";
              pyproject = true;
              src = pkgs.fetchFromGitHub {
                owner = "nickolaj-jepsen";
                repo = "zwift-client";
                rev = "882fb881f1271dc104fd0250cab4ceb6e3710a59";
                hash = "sha256-4gOlWG+QVwODlIhiNH7rhiD0rzNv2WxY2ty9o/51eHU=";
              };
              doCheck = false;
              propagatedBuildInputs = with pkgs.python313.pkgs; [
                hatchling
                requests
                protobuf
              ];
            })
          ];
        })
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
