# Root-only: reads the broker password itself, so it stays out of shell history and out
# of this script's own argv. It is still visible in the mosquitto_sub/pub child's argv
# (via -P) for the life of the call; the clients offer no env or file alternative.
{
  pkgs,
  config,
  port,
}:
pkgs.writeShellApplication {
  name = "z2m-mqtt";
  runtimeInputs = [pkgs.mosquitto pkgs.coreutils];
  text = ''
    pw=$(cat ${config.age.secrets.mosquitto-zigbee2mqtt.path})
    cmd=''${1:-}; shift || true
    case "$cmd" in
      sub) exec mosquitto_sub -h 127.0.0.1 -p ${toString port} -u zigbee2mqtt -P "$pw" -C 1 -W 10 -t "$@" ;;
      pub) exec mosquitto_pub -h 127.0.0.1 -p ${toString port} -u zigbee2mqtt -P "$pw" -t "$1" -m "$2" ;;
      *) echo "usage: z2m-mqtt sub <topic> [mosquitto_sub args] | pub <topic> <payload>" >&2; exit 2 ;;
    esac
  '';
}
