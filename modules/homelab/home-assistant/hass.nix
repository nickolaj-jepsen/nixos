{
  flake.modules.nixos.home-assistant-hass = {
    pkgs,
    config,
    lib,
    fpLib,
    ...
  }: let
    cfg = config.fireproof.homelab;
    homeAssistantPort = 8123;
    configDir = config.services.home-assistant.configDir;
    dev = import ./_devices.nix {inherit lib;};
    automations = import ./_automations.nix {inherit lib dev;};

    batteryTable = lib.concatStringsSep ", " (lib.mapAttrsToList (n: d: "'${dev.battery n}': [${toString d.threshold}, '${n}', '${d.cells}']") dev.batteryDevices);
    jinjaList = xs: "[${lib.concatStringsSep ", " (map (e: "'${e}'") xs)}]";
    watchList = jinjaList automations.zigbeeWatch;
    updateList = jinjaList dev.updateEntities;
    linkList = jinjaList dev.linkqualityEntities;

    # detect_non_ha_changes: lights are turned on via Zigbee2MQTT groups, which AL
    # cannot intercept; without it AL marks those bulbs manual and never adapts them.
    # MQTT lights do not poll, so it costs nothing.
    adaptiveProfile = room: extra:
      {
        name = room;
        lights = map dev.light dev.rooms.${room}.lights;
        interval = 300;
        transition = 5;
        initial_transition = 1;
        skip_redundant_commands = true;
        take_over_control = true;
        detect_non_ha_changes = true;
        separate_turn_on_commands = false;
        min_color_temp = 2200;
        max_color_temp = 4000;
        sleep_brightness = 5;
        sleep_color_temp = 2200;
      }
      // extra;
    # The office keeps AL's defaults (1 % floor, 5 % asleep). Every other room sits a
    # little above it: a passage lit like the office is too dark to be of use.
    passage = {
      min_brightness = 10;
      sleep_brightness = 10;
    };
    living = {
      min_brightness = 5;
      sleep_brightness = 8;
    };
    alExtra = {
      stairs = passage // {max_brightness = 67;};
      entrance = passage;
      bathroom = passage;
      living_room = living;
      bedroom =
        living
        // {
          max_sunrise_time = "07:00:00";
          max_sunset_time = "20:00:00";
        };
    };
  in {
    config = lib.mkIf cfg.enable {
      age.secrets.hassSecrets = {
        rekeyFile = ../../../secrets/hosts/homelab/hass.yaml.age;
        path = "${configDir}/secrets.yaml";
        mode = "400";
        owner = "hass";
        group = "hass";
      };

      services.restic.backups.homelab.paths = [configDir];

      services.nginx.virtualHosts."ha.${cfg.domain}" = fpLib.mkVirtualHost {
        port = homeAssistantPort;
        websockets = true;
      };

      # stopIfChanged/RestartSec/start limit: see mqtt.nix.
      systemd.services.home-assistant = {
        after = ["mosquitto.service"];
        wants = ["mosquitto.service"];
        stopIfChanged = false;
        startLimitIntervalSec = 120;
        startLimitBurst = 5;
        serviceConfig.RestartSec = "5s";
      };

      services.home-assistant = {
        enable = true;
        package = pkgs.unstable.home-assistant;
        customComponents = [
          pkgs.unstable.home-assistant-custom-components.adaptive_lighting
          (import ./_zwift.nix {inherit pkgs;})
          (import ./_bambu.nix {inherit pkgs;})
        ];
        # Config-flow integrations (set up in the UI) still need their deps built in.
        # Only these: the module already adds every top-level `config` key below, plus its
        # readOnly defaultIntegrations. Listing those again builds the same derivation.
        extraComponents = [
          "isal"
          "mqtt"
          "unifi"
          "google"
          "spotify"
          "jellyfin"
          "sleep_as_android"
          "met"
          "mcp_server"
          # ha-bambulab depends on ffmpeg; nixpkgs patches in the absolute binary path.
          "ffmpeg"
        ];
        lovelaceConfig = import ./_dashboard.nix {inherit lib dev;};
        config = {
          # lovelaceConfig alone registers an "Overview" panel; set it as default per user once.
          lovelace.dashboards.nixos-lovelace = {
            mode = "yaml";
            filename = "ui-lovelace.yaml";
            title = "Home";
            icon = "mdi:home";
            show_in_sidebar = true;
          };
          homeassistant = {
            name = "Home";
            latitude = "!secret latitude";
            longitude = "!secret longitude";
            elevation = "!secret elevation";
            unit_system = "metric";
            time_zone = "Europe/Copenhagen";
            currency = "DKK";
            country = "DK";
            external_url = "https://ha.${cfg.domain}";
          };
          # The module always renders an http: block, and HA migrates it into .storage/http
          # exactly once. Declaring the proxy keys here is what makes that one-shot seed
          # correct on a rebuilt data dir: without them every request is attributed to
          # nginx on 127.0.0.1, so five failed logins ban the proxy and lock everyone out.
          http = {
            use_x_forwarded_for = true;
            trusted_proxies = ["127.0.0.1" "::1"];
          };
          frontend = {};
          config = {};
          my = {};
          system_health = {};
          mobile_app = {};
          sun = {};
          history = {};
          logbook = {};
          recorder = {
            purge_keep_days = 30;
            commit_interval = 5;
            exclude.entity_globs = ["sensor.*_linkquality" "sensor.*_last_seen"];
            # These two embed raw LQI values in their attributes, so excluding the
            # linkquality sensors alone would not stop the per-report state rows.
            # zigbee2mqtt_health updates every 10 min with per-device counters; only the current value matters.
            exclude.entities = ["sensor.zigbee_weak_links" "sensor.zigbee_health_report" dev.z2m.health];
          };

          input_boolean = {
            sleep_mode = {
              name = "Sleep mode";
              icon = "mdi:sleep";
            };
            guest_mode = {
              name = "Guest mode";
              icon = "mdi:account-group";
            };
            stairs_manual = {
              name = "Stairs switched manually";
              icon = "mdi:hand-back-right";
            };
            entrance_manual = {
              name = "Entrance switched manually";
              icon = "mdi:hand-back-right";
            };
            zwift_ride = {
              name = "Zwift ride";
              icon = "mdi:bike";
            };
            watching_manual = {
              name = "Living room switched during playback";
              icon = "mdi:hand-back-right";
            };
            mqtt_triggers_armed = {
              name = "MQTT triggers armed";
              icon = "mdi:antenna";
            };
            away_simulation = {
              name = "Away simulation";
              icon = "mdi:home-clock";
            };
          };

          # province is a case-insensitive regex on the alert's area name; tighten the alternation
          # once a real warning shows DMI's exact name for the Aarhus area.
          binary_sensor = [
            {
              platform = "meteoalarm";
              country = "denmark";
              province = "Østjylland|East Jutland|Midtjylland";
              language = "da-DK";
            }
          ];

          mqtt.sensor = [
            {
              name = "Zigbee2MQTT health";
              unique_id = "zigbee2mqtt_health";
              state_topic = "zigbee2mqtt/bridge/health";
              value_template = "{{ value_json.mqtt.queued }}";
              unit_of_measurement = "msgs";
              icon = "mdi:heart-pulse";
              json_attributes_topic = "zigbee2mqtt/bridge/health";
              json_attributes_template = "{{ {'response_time': value_json.response_time, 'process': value_json.process, 'os': value_json.os, 'mqtt': value_json.mqtt, 'devices': value_json.devices} | tojson }}";
            }
          ];

          # The arr Discord channel.
          rest_command.discord = {
            url = "!secret discord_webhook";
            method = "POST";
            content_type = "application/json";
            payload = ''{"content": {{ message | tojson }}}'';
          };

          template = [
            {
              sensor = [
                {
                  name = "Zigbee low batteries";
                  unique_id = "zigbee_low_batteries";
                  icon = "mdi:battery-alert";
                  state = ''
                    {% set t = {${batteryTable}} %}
                    {% set ns = namespace(n=0) %}
                    {% for e, v in t.items() %}
                      {% set pct = states(e) %}
                      {% if pct not in ['unknown','unavailable'] and pct | int(100) <= v[0] %}
                        {% set ns.n = ns.n + 1 %}
                      {% endif %}
                    {% endfor %}
                    {{ ns.n }}
                  '';
                  attributes = {
                    items = ''
                      {% set t = {${batteryTable}} %}
                      {% set ns = namespace(out=[]) %}
                      {% for e, v in t.items() %}
                        {% set pct = states(e) %}
                        {% if pct not in ['unknown','unavailable'] and pct | int(100) <= v[0] %}
                          {% set ns.out = ns.out + [v[1] ~ ' ' ~ pct ~ '% (' ~ v[2] ~ ')'] %}
                        {% endif %}
                      {% endfor %}
                      {{ ns.out }}
                    '';
                    all = ''
                      {% set t = {${batteryTable}} %}
                      {% set ns = namespace(out=[]) %}
                      {% for e, v in t.items() %}
                        {% set ns.out = ns.out + [v[1] ~ ' ' ~ states(e) ~ '%'] %}
                      {% endfor %}
                      {{ ns.out }}
                    '';
                  };
                }
                {
                  name = "Zigbee unavailable";
                  unique_id = "zigbee_unavailable";
                  icon = "mdi:lan-disconnect";
                  state = "{{ ${watchList} | select('is_state', 'unavailable') | list | count }}";
                  attributes.items = ''
                    {% set ns = namespace(out=[]) %}
                    {% for e in ${watchList} %}
                      {% if states(e) == 'unavailable' %}
                        {% set ns.out = ns.out + [state_attr(e, 'friendly_name') or e] %}
                      {% endif %}
                    {% endfor %}
                    {{ ns.out }}
                  '';
                }
                {
                  name = "Zigbee updates";
                  unique_id = "zigbee_updates";
                  icon = "mdi:update";
                  state = "{{ ${updateList} | select('is_state', 'on') | list | count }}";
                  attributes.items = "{{ ${updateList} | select('is_state', 'on') | map('state_attr', 'friendly_name') | list }}";
                }
                {
                  # LQI 0-255; under 30 IKEA remotes start losing presses. The sensors are discovered disabled.
                  name = "Zigbee weak links";
                  unique_id = "zigbee_weak_links";
                  icon = "mdi:signal-cellular-1";
                  state = ''
                    {% set ns = namespace(n=0) %}
                    {% for e in ${linkList} %}
                      {% set v = states(e) %}
                      {% if v not in ['unknown','unavailable'] and v | int(255) < 30 %}
                        {% set ns.n = ns.n + 1 %}
                      {% endif %}
                    {% endfor %}
                    {{ ns.n }}
                  '';
                  attributes = {
                    items = ''
                      {% set ns = namespace(out=[]) %}
                      {% for e in ${linkList} %}
                        {% set v = states(e) %}
                        {% if v not in ['unknown','unavailable'] and v | int(255) < 30 %}
                          {% set ns.out = ns.out + [(state_attr(e, 'friendly_name') or e) ~ ' (' ~ v ~ ')'] %}
                        {% endif %}
                      {% endfor %}
                      {{ ns.out }}
                    '';
                    # 0 only means "all fine" when this is non-zero (sensors enabled).
                    reporting = "{{ ${linkList} | reject('is_state', 'unknown') | reject('is_state', 'unavailable') | list | count }}";
                  };
                }
                {
                  name = "Zigbee health report";
                  unique_id = "zigbee_health_report";
                  icon = "mdi:clipboard-pulse";
                  state = "{{ states('sensor.zigbee_low_batteries') | int(0) + states('sensor.zigbee_unavailable') | int(0) + states('sensor.zigbee_updates') | int(0) + states('sensor.zigbee_weak_links') | int(0) }}";
                  attributes.report = ''
                    {% set lb = state_attr('sensor.zigbee_low_batteries','items') or [] %}
                    {% set un = state_attr('sensor.zigbee_unavailable','items') or [] %}
                    {% set up = state_attr('sensor.zigbee_updates','items') or [] %}
                    {% set wl = state_attr('sensor.zigbee_weak_links','items') or [] %}
                    🔋 Low batteries: {{ lb | join(', ') if lb else 'none' }}
                    📵 Unreachable: {{ un | join(', ') if un else 'none' }}
                    ⬆️ Firmware updates: {{ up | join(', ') if up else 'none' }}
                    📶 Weak links: {{ wl | join(', ') if wl else 'none' }}
                  '';
                }
              ];
            }
          ];

          # Driven by dev.alRooms, which sleep_mode_sync also targets.
          adaptive_lighting = map (r: adaptiveProfile r (alExtra.${r} or {})) dev.alRooms;

          inherit (automations) automation;
          inherit (automations) script;
          scene = [];
        };
      };
    };
  };
}
