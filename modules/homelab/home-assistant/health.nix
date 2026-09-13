{
  flake.modules.nixos.home-assistant-health = {
    config,
    lib,
    pkgs,
    ...
  }: let
    # Read from the services themselves: a hard-coded copy would silently probe a dead
    # port and report a false outage if either listener ever moves.
    z2mMqtt = import ./_z2m-mqtt.nix {
      inherit pkgs config;
      inherit ((lib.head config.services.mosquitto.listeners)) port;
    };
    haPort = config.services.home-assistant.config.http.server_port;
    # Reuses the #sys-info webhook declared in nextcloud.nix (same homelab gate).
    discordEnv = config.age.secrets.discord-webhook-sys-info.path;
    discordPost = ''
      post() { jq -nc --arg c "$1" '{content: $c}' | curl -fsS -H 'Content-Type: application/json' -d @- "$DISCORD_WEBHOOK_SYS_INFO" >/dev/null || true; }
    '';
  in {
    config = lib.mkIf config.fireproof.homelab.enable {
      # Readiness after every HA/Z2M start ("Started" only means spawned), posted to
      # Discord as evidence for the next "nothing worked after an update".
      systemd.services.home-assistant.wants = ["homelab-health-check.service"];
      systemd.services.zigbee2mqtt.wants = ["homelab-health-check.service"];
      systemd.services.homelab-health-check = {
        description = "Home Assistant + Zigbee2MQTT readiness check → Discord";
        after = ["home-assistant.service" "zigbee2mqtt.service" "mosquitto.service"];
        path = [pkgs.systemd];
        serviceConfig = {
          Type = "oneshot";
          EnvironmentFile = discordEnv;
          ExecStart = lib.getExe (pkgs.writeShellApplication {
            name = "homelab-health-check";
            runtimeInputs = [z2mMqtt pkgs.curl pkgs.jq pkgs.coreutils pkgs.gnugrep];
            text = ''
              ${discordPost}
              deadline=300
              start=$(date +%s)
              ha=""; z2m=""
              # Deadline-driven, not iteration-driven: each pass also spends up to 3 s in the
              # MQTT probe, so a fixed count would overshoot the number in the message below.
              while [ $(( $(date +%s) - start )) -lt "$deadline" ]; do
                # /auth/providers needs no token; /api/ without one counts as a failed login and feeds the IP ban.
                if [ -z "$ha" ]; then
                  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${toString haPort}/auth/providers" || true)
                  [ "$code" = 200 ] && ha=$(( $(date +%s) - start ))
                fi
                if [ -z "$z2m" ] && [ "$(z2m-mqtt sub zigbee2mqtt/bridge/state -W 3 2>/dev/null | jq -r .state)" = online ]; then
                  z2m=$(( $(date +%s) - start ))
                fi
                [ -n "$ha" ] && [ -n "$z2m" ] && break
                sleep 5
              done
              msg="homelab: Home Assistant $( [ -n "$ha" ] && echo "up after ''${ha}s" || echo "NOT up after ''${deadline}s" ), Zigbee2MQTT $( [ -n "$z2m" ] && echo "online after ''${z2m}s" || echo "NOT online after ''${deadline}s" )"
              echo "$msg"
              post "$msg"
              # Deliberately exit 0: the Discord post and the journal line are the signal. A
              # non-zero exit would leave the unit failed, so every later switch ends in
              # "units failed" — the symptom the oauth2-proxy gate in this branch removed.
            '';
          });
        };
      };

      # The coordinator once hung for 14 h with the process up and MQTT connected, every
      # serial request timing out ("SRSP ... after 6000ms"); Z2M's watchdog only covers crashes.
      systemd.services.zigbee2mqtt-watchdog = {
        description = "Restart Zigbee2MQTT when the coordinator stops answering";
        path = [pkgs.systemd];
        serviceConfig = {
          Type = "oneshot";
          EnvironmentFile = discordEnv;
          ExecStart = lib.getExe (pkgs.writeShellApplication {
            name = "zigbee2mqtt-watchdog";
            runtimeInputs = [pkgs.curl pkgs.jq pkgs.coreutils pkgs.gnugrep];
            text = ''
              ${discordPost}
              stamp=/run/zigbee2mqtt-watchdog.last
              systemctl is-active --quiet zigbee2mqtt.service || exit 0
              # Ignore the first 15 min after a start: the adapter is still settling.
              started=$(systemctl show zigbee2mqtt.service -p ActiveEnterTimestampMonotonic --value)
              now=$(( $(cut -d. -f1 /proc/uptime) * 1000000 ))
              [ $(( now - started )) -gt $(( 15 * 60 * 1000000 )) ] || exit 0
              n=$(journalctl -u zigbee2mqtt.service --since -10min -o cat | grep -c 'SRSP - ' || true)
              [ "$n" -ge 15 ] || exit 0
              if [ -f "$stamp" ] && [ $(( $(date +%s) - $(cat "$stamp") )) -lt 3600 ]; then
                echo "coordinator still unresponsive ($n serial timeouts / 10 min), restarted less than an hour ago"
                exit 0
              fi
              date +%s > "$stamp"
              echo "restarting zigbee2mqtt: $n serial timeouts in the last 10 min"
              systemctl restart zigbee2mqtt.service
              post "homelab: Zigbee coordinator stopped answering ($n serial timeouts in 10 min); restarted Zigbee2MQTT"
            '';
          });
        };
      };
      systemd.timers.zigbee2mqtt-watchdog = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "20min";
          OnUnitActiveSec = "5min";
        };
      };
    };
  };
}
