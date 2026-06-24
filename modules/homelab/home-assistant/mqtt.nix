{
  flake.modules.nixos.home-assistant-mqtt = {
    config,
    lib,
    fpLib,
    ...
  }: let
    cfg = config.fireproof.homelab;
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

      services.oauth2-proxy.nginx.virtualHosts."zigbee.${cfg.domain}".allowed_groups = ["iot-admin"];
      services.nginx.virtualHosts."zigbee.${cfg.domain}" = fpLib.mkVirtualHost {
        port = zigbee2mqttPort;
        websockets = true;
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

      # zigbee2mqtt connects to mosquitto on localhost but the upstream module adds
      # no ordering, and it shares zitadel's fragile profile (Restart=on-failure,
      # StartLimitBurst=5/10s). Today it survives only because Zigbee coordinator
      # init delays its MQTT connect past mosquitto startup; order it explicitly so
      # a slow boot can't make it crash-loop into start-limit-hit. See sso/zitadel.nix.
      systemd.services.zigbee2mqtt = {
        after = ["mosquitto.service"];
        requires = ["mosquitto.service"];
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
            # debug emits ~10k journal lines/h (zigbee-herdsman zstack parser spam) and
            # dominates Loki ingest; warn keeps it readable. Flip to debug only while pairing.
            log_level = "warn";
          };
        };
      };
    };
  };
}
