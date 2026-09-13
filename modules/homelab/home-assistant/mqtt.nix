{
  flake.modules.nixos.home-assistant-mqtt = {
    config,
    lib,
    pkgs,
    fpLib,
    ...
  }: let
    cfg = config.fireproof.homelab;
    mosquittoPort = 1883;
    zigbee2mqttPort = 8180;
    z2mSecret = config.age.secrets."zigbee2mqtt-secret.yaml".path;

    dev = import ./_devices.nix {inherit lib;};

    # Group ids/names are settings; membership lives in Z2M's database.db and on the
    # bulbs, reconciled by zigbee2mqtt-groups-sync. One multicast per command, so a
    # wall-switched member never stalls the radio. Derived from _devices.nix so a bulb
    # added to a room cannot reach Adaptive Lighting and the dashboard but miss the group.
    # The ids are live keys in database.db and on the bulbs: pin them, never derive.
    groupIds = {
      "1" = "office";
      "2" = "stairs";
      "3" = "entrance";
      "4" = "bathroom";
      "5" = "bedroom";
      "6" = "living_room";
    };
    zigbeeGroups =
      lib.mapAttrs (_: room: {
        friendly_name = dev.groups.${room};
        members = dev.rooms.${room}.lights;
      })
      groupIds
      // {
        "7" = {
          friendly_name = dev.groups.all;
          members = dev.allLights;
        };
      };
    desiredGroupsJson = pkgs.writeText "zigbee-groups.json" (builtins.toJSON (
      lib.mapAttrs' (_: g: lib.nameValuePair g.friendly_name g.members) zigbeeGroups
    ));

    z2mMqtt = import ./_z2m-mqtt.nix {
      inherit pkgs config;
      port = mosquittoPort;
    };
  in {
    config = lib.mkIf cfg.enable {
      age.secrets = {
        # Keys: password (MQTT), network_key (Zigbee, list of 16 ints), frontend_token.
        "zigbee2mqtt-secret.yaml" = {
          rekeyFile = ../../../secrets/hosts/homelab/zigbee2mqtt-secret.yaml.age;
          owner = "zigbee2mqtt";
          group = "zigbee2mqtt";
        };
        mosquitto-zigbee2mqtt.rekeyFile = ../../../secrets/hosts/homelab/mosquitto-zigbee2mqtt.age;
        mosquitto-ha.rekeyFile = ../../../secrets/hosts/homelab/mosquitto-ha.age;
      };

      environment.systemPackages = [z2mMqtt];

      services.restic.backups.homelab = {
        paths = [config.services.zigbee2mqtt.dataDir];
        exclude = ["/var/lib/zigbee2mqtt/log/"];
      };

      services.oauth2-proxy.nginx.virtualHosts."zigbee.${cfg.domain}".allowed_groups = ["iot-admin"];
      services.nginx.virtualHosts."zigbee.${cfg.domain}" = fpLib.mkVirtualHost {
        port = zigbee2mqttPort;
        websockets = true;
      };

      # Loopback only: both users hold `readwrite #`.
      services.mosquitto = {
        enable = true;
        listeners = [
          {
            address = "127.0.0.1";
            port = mosquittoPort;
            users."zigbee2mqtt" = {
              acl = ["readwrite #"];
              passwordFile = config.age.secrets.mosquitto-zigbee2mqtt.path;
            };
            users."homeassistant" = {
              acl = ["readwrite #"];
              passwordFile = config.age.secrets.mosquitto-ha.path;
            };
          }
        ];
      };

      # stopIfChanged=false: restart after activation instead of stop-before (no ExecStop,
      # so nothing to gain; 15-30 s of dead time per switch). RestartSec 100 ms with the
      # default 5-in-10 s limit leaves a crashing unit dead within a second.
      systemd.services.mosquitto = {
        stopIfChanged = false;
        startLimitIntervalSec = 120;
        startLimitBurst = 5;
        serviceConfig.RestartSec = "5s";
      };

      # Wants, not Requires: a broker restart must not take Z2M down; it reconnects.
      systemd.services.zigbee2mqtt = {
        after = ["mosquitto.service"];
        wants = ["mosquitto.service" "zigbee2mqtt-groups-sync.service"];
        stopIfChanged = false;
      };

      # After each Z2M start and daily: a wall-switched bulb joins once it is back.
      systemd.services.zigbee2mqtt-groups-sync = {
        description = "Reconcile Zigbee2MQTT group membership with the Nix definition";
        after = ["zigbee2mqtt.service"];
        serviceConfig = {
          Type = "oneshot";
          # Worst case: 30 x 10 s bridge wait + 34 members x ~48 s (see -W below).
          TimeoutStartSec = "45min";
          ExecStart = lib.getExe (pkgs.writeShellApplication {
            name = "zigbee2mqtt-groups-sync";
            runtimeInputs = [z2mMqtt pkgs.jq pkgs.coreutils];
            text = ''
              base=zigbee2mqtt
              online=""
              for _ in $(seq 1 30); do
                if [ "$(z2m-mqtt sub $base/bridge/state -W 5 2>/dev/null | jq -r .state)" = online ]; then online=1; break; fi
                sleep 5
              done
              if [ -z "$online" ]; then
                echo "Zigbee2MQTT never came online, skipping group sync" >&2
                exit 0
              fi
              # A timed-out subscribe exits 27; without the guard it would kill the script
              # before the per-member diagnostics below ever run.
              devices=$(z2m-mqtt sub $base/bridge/devices -W 10 || true)
              groups=$(z2m-mqtt sub $base/bridge/groups -W 10 || true)
              if [ -z "$devices" ] || [ -z "$groups" ]; then
                echo "no retained device/group state from the bridge, skipping group sync" >&2
                exit 0
              fi
              # One pass each, then pure bash lookups: per-member jq re-parsed the whole
              # ~130 KB device list twice per pair (68 spawns, ~1.8 s) for no gain.
              declare -A ieeeOf=() memberOf=()
              while IFS=$'\t' read -r n i; do ieeeOf["$n"]=$i; done < <(jq -r '.[] | [.friendly_name, .ieee_address] | @tsv' <<<"$devices")
              while IFS=$'\t' read -r g i; do memberOf["$g/$i"]=1; done < <(jq -r '.[] | .friendly_name as $g | .members[] | [$g, .ieee_address] | @tsv' <<<"$groups")
              missing=""
              while IFS=$'\t' read -r group member; do
                ieee=''${ieeeOf["$member"]:-}
                if [ -z "$ieee" ]; then
                  echo "skip: '$member' is not paired" >&2
                  missing="$missing '$member' (not paired);"
                  continue
                fi
                if [ -n "''${memberOf["$group/$ieee"]:-}" ]; then
                  continue
                fi
                # Z2M already knows when a wall-switched member is off; asking it anyway
                # costs the full retry cycle below for nothing.
                if [ "$(z2m-mqtt sub "$base/$member/availability" -W 2 2>/dev/null | jq -r .state)" = offline ]; then
                  echo "skip: '$member' is offline" >&2
                  missing="$missing '$member' (offline);"
                  continue
                fi
                echo "adding '$member' to '$group'"
                # -W 45 covers zigbee-herdsman's worst case for a member Z2M believes online
                # (five data-request attempts with route discovery, or two 10 s response
                # timeouts); the transaction id keeps a late reply from being read as the next one's.
                t="$group/$member"
                resp=$(z2m-mqtt sub $base/bridge/response/group/members/add -W 45 & sleep 1
                       z2m-mqtt pub $base/bridge/request/group/members/add "$(jq -nc --arg g "$group" --arg d "$member" --arg t "$t" '{group: $g, device: $d, transaction: $t}')"
                       wait)
                if [ "$(jq -r --arg t "$t" 'select(.transaction == $t) | .status' <<<"$resp" 2>/dev/null)" != ok ]; then
                  # jq yields nothing at all on empty input, so the reason needs its own guard.
                  reason=$(jq -r --arg t "$t" 'if .transaction == $t then (.error // "unknown error") else "stale response" end' <<<"$resp" 2>/dev/null || true)
                  echo "failed: '$member' -> '$group': ''${reason:-no response}" >&2
                  missing="$missing '$member' -> '$group';"
                fi
              done < <(jq -r 'to_entries[] | .key as $g | .value[] | [$g, .] | @tsv' ${desiredGroupsJson})
              if [ -n "$missing" ]; then
                echo "group sync incomplete:$missing" >&2
              fi
            '';
          });
        };
      };
      systemd.timers.zigbee2mqtt-groups-sync = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "04:10";
          Persistent = true;
        };
      };

      services.zigbee2mqtt = {
        enable = true;
        settings = {
          # Without it Z2M re-runs migrations v1..v5 on every start (ExecStartPre copies
          # this file in) and wipes cached OTA state; an unsupported value refuses to start.
          version = 5;
          homeassistant = {
            enabled = true;
          };
          mqtt = {
            base_topic = "zigbee2mqtt";
            server = "mqtt://127.0.0.1:${toString mosquittoPort}";
            user = "zigbee2mqtt";
            password = "!${z2mSecret} password";
          };
          # The frontend can pair/remove devices and read the network key: loopback + token.
          frontend = {
            enabled = true;
            host = "127.0.0.1";
            port = zigbee2mqttPort;
            auth_token = "!${z2mSecret} frontend_token";
          };
          serial = {
            port = "/dev/serial/by-id/usb-Silicon_Labs_Sonoff_Zigbee_3.0_USB_Dongle_Plus_0001-if00-port0";
            adapter = "zstack";
          };
          # Unreachable devices go `unavailable` in HA (out of Adaptive Lighting and every
          # condition); pause_on_backoff_gt stops pinging a wall-switched bulb after ~2.5 h.
          availability = {
            enabled = true;
            active = {
              timeout = 10;
              pause_on_backoff_gt = 6;
            };
            passive = {
              timeout = 1500;
            };
          };
          advanced = {
            # Network identity: changing any of these re-pairs every device. The old
            # plaintext key is still in git history.
            network_key = "!${z2mSecret} network_key";
            pan_id = 6754; # 0x1a62
            ext_pan_id = [221 221 221 221 221 221 221 221]; # Z-Stack maps this sentinel to the dongle's own IEEE
            channel = 25;
            last_seen = "ISO_8601";
            # debug is ~10k journal lines/h and dominates Loki; use it only while pairing.
            log_level = "warning";
          };
          groups = lib.mapAttrs (_: g: {inherit (g) friendly_name;}) zigbeeGroups;
        };
      };
    };
  };
}
