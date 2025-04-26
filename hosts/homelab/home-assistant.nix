{
  pkgsUnstable,
  pkgs,
  config,
  ...
}: let
  mosquittoPort = 1883;
  zigbee2mqttPort = 8180;
  homeAssistantPort = 8123;
in {
  age.secrets = {
    "zigbee2mqtt-secret.yaml" = {
      rekeyFile = ../../secrets/hosts/homelab/zigbee2mqtt-secret.yaml.age;
      owner = "zigbee2mqtt";
      group = "zigbee2mqtt";
    };
    mosquitto-zigbee2mqtt.rekeyFile = ../../secrets/hosts/homelab/mosquitto-zigbee2mqtt.age;
    mosquitto-sas.rekeyFile = ../../secrets/hosts/homelab/mosquitto-sas.age;
    mosquitto-ha.rekeyFile = ../../secrets/hosts/homelab/mosquitto-ha.age;
  };

  networking.firewall.allowedTCPPorts = [
    mosquittoPort
  ];

  services = {
    restic.backups.homelab = {
      paths = [
        config.services.zigbee2mqtt.dataDir
        config.services.home-assistant.configDir
      ];
      exclude = [
        "/var/lib/zigbee2mqtt/log/"
      ];
    };

    oauth2-proxy.nginx.virtualHosts."zigbee.nickolaj.com".allowed_groups = ["iot-admin"];
    nginx.virtualHosts = {
      "zigbee.nickolaj.com" = {
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://localhost:${toString zigbee2mqttPort}";
          proxyWebsockets = true;
        };
      };
      "ha.nickolaj.com" = {
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://localhost:${toString homeAssistantPort}";
          proxyWebsockets = true;
        };
      };
    };

    home-assistant = {
      enable = true;
      package = pkgsUnstable.home-assistant;
      customComponents = with pkgsUnstable.home-assistant-custom-components; [
        adaptive_lighting
        sleep_as_android
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
      ];
      extraComponents = [
        "default_config"
        "met"
        "mqtt"
        "esphome"
        "google"
        "spotify"
        "unifi"
        "upnp"
        "homeassistant_hardware"
      ];
      config = {
        homeassistant = {
          name = "Home";
          latitude = "56.2";
          longitude = "10.2";
          elevation = "0";
          unit_system = "metric";
          time_zone = "Europe/Copenhagen";
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
          base_url = "https://ha.nickolaj.com";
        };

        automation = "!include automations.yaml";
        script = "!include scripts.yaml";
        scene = "!include scenes.yaml";
      };
    };

    mosquitto = {
      enable = true;
      listeners = [
        {
          port = mosquittoPort;
          users."zigbee2mqtt" = {
            acl = ["readwrite #"];
            passwordFile = "${config.age.secrets.mosquitto-zigbee2mqtt.path}";
          };
          users."homeassistant" = {
            acl = ["readwrite #"];
            passwordFile = "${config.age.secrets.mosquitto-ha.path}";
          };
          users."sleep_as_android" = {
            acl = ["readwrite SleepAsAndroid"];
            passwordFile = "${config.age.secrets.mosquitto-sas.path}";
          };
        }
      ];
    };

    zigbee2mqtt = {
      enable = true;
      settings = {
        homeassistant = {
          enabled = true;
        };
        mqtt = {
          base_topic = "zigbee2mqtt";
          server = "mqtt://localhost:${toString mosquittoPort}";
          user = "zigbee2mqtt";
          password = "!${config.age.secrets."zigbee2mqtt-secret.yaml".path} password";
        };
        frontend = {
          enabled = true;
          port = zigbee2mqttPort;
        };
        serial = {
          port = "/dev/serial/by-id/usb-Silicon_Labs_Sonoff_Zigbee_3.0_USB_Dongle_Plus_0001-if00-port0";
          adapter = "zstack";
        };
        advanced = {
          network_key = [
            233
            138
            136
            76
            51
            117
            128
            127
            74
            84
            33
            179
            116
            61
            79
            101
          ];
          channel = 25;
          log_level = "debug";
        };
      };
    };
  };
}
