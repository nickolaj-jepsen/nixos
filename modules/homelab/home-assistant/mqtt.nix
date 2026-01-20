{
  config,
  lib,
  ...
}: let
  mosquittoPort = 1883;
  zigbee2mqttPort = 8180;
in {
  config = lib.mkIf config.fireproof.homelab.enable {
    age.secrets = {
      "zigbee2mqtt-secret.yaml" = {
        rekeyFile = ../../../secrets/hosts/homelab/zigbee2mqtt-secret.yaml.age;
        owner = "zigbee2mqtt";
        group = "zigbee2mqtt";
      };
      mosquitto-zigbee2mqtt.rekeyFile = ../../../secrets/hosts/homelab/mosquitto-zigbee2mqtt.age;
      mosquitto-sas.rekeyFile = ../../../secrets/hosts/homelab/mosquitto-sas.age;
      mosquitto-ha.rekeyFile = ../../../secrets/hosts/homelab/mosquitto-ha.age;
    };

    networking.firewall.allowedTCPPorts = [mosquittoPort];

    services.restic.backups.homelab = {
      paths = [config.services.zigbee2mqtt.dataDir];
      exclude = ["/var/lib/zigbee2mqtt/log/"];
    };

    services.oauth2-proxy.nginx.virtualHosts."zigbee.nickolaj.com".allowed_groups = ["iot-admin"];
    services.nginx.virtualHosts."zigbee.nickolaj.com" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://localhost:${toString zigbee2mqttPort}";
        proxyWebsockets = true;
      };
    };

    services.mosquitto = {
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

    services.zigbee2mqtt = {
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
