{
  config,
  lib,
  pkgs,
  ...
}:
lib.mkIf config.fireproof.homelab.enable (let
  inherit (config.fireproof) username;
  user = "media";
  group = "media";

  # VPN namespace configuration
  vpnNamespace = "vpn";
  vpnInterface = "wg0";

  # Ports
  webUiPort = 8082;
  torrentPort = 51413;

  mkVirtualHost = port: {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://localhost:${toString port}";
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };
  };
in {
  # Secrets for Mullvad WireGuard config
  # mullvad-wg.age should contain just the WireGuard config (not the Address line):
  #   [Interface]
  #   PrivateKey = <your-private-key>
  #
  #   [Peer]
  #   PublicKey = <mullvad-server-pubkey>
  #   AllowedIPs = 0.0.0.0/0
  #   Endpoint = <server>:51820
  age.secrets.mullvad-wg = {
    rekeyFile = ../../secrets/hosts/homelab/mullvad-wg.age;
    mode = "400";
  };

  # mullvad-wg-address.age should contain just the IP address assigned by Mullvad, e.g.:
  #   10.66.123.45/32
  age.secrets.mullvad-wg-address = {
    rekeyFile = ../../secrets/hosts/homelab/mullvad-wg-address.age;
    mode = "444";
  };

  # Create the VPN network namespace and WireGuard interface
  systemd.services."netns-${vpnNamespace}" = {
    description = "VPN Network Namespace";
    before = ["qbittorrent.service"];
    wantedBy = ["multi-user.target"];
    path = with pkgs; [iproute2 iptables];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "create-vpn-netns" ''
        set -ex
        # Create network namespace if it doesn't exist
        ip netns add ${vpnNamespace} || true

        # Create veth pair for communication between namespaces
        ip link add veth-vpn type veth peer name veth-vpn-br || true
        ip link set veth-vpn-br netns ${vpnNamespace} || true

        # Configure host side
        ip addr add 10.200.200.1/24 dev veth-vpn || true
        ip link set veth-vpn up

        # Configure namespace side
        ip netns exec ${vpnNamespace} ip addr add 10.200.200.2/24 dev veth-vpn-br || true
        ip netns exec ${vpnNamespace} ip link set veth-vpn-br up
        ip netns exec ${vpnNamespace} ip link set lo up

        # Enable IP forwarding for the veth bridge
        echo 1 > /proc/sys/net/ipv4/ip_forward
        iptables -t nat -A POSTROUTING -s 10.200.200.0/24 -o veth-vpn -j MASQUERADE || true

        # Allow traffic from namespace to host for web UI
        iptables -A FORWARD -i veth-vpn -o veth-vpn -j ACCEPT || true
      '';
      ExecStop = pkgs.writeShellScript "destroy-vpn-netns" ''
        ip link del veth-vpn || true
        ip netns del ${vpnNamespace} || true
        iptables -t nat -D POSTROUTING -s 10.200.200.0/24 -o veth-vpn -j MASQUERADE || true
      '';
    };
  };

  # WireGuard interface inside the VPN namespace
  systemd.services."wg-${vpnNamespace}" = {
    description = "WireGuard VPN in namespace";
    after = ["netns-${vpnNamespace}.service"];
    requires = ["netns-${vpnNamespace}.service"];
    before = ["qbittorrent.service"];
    wantedBy = ["multi-user.target"];
    path = with pkgs; [iproute2 wireguard-tools];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "setup-wg-vpn" ''
        set -ex
        # Create WireGuard interface in namespace
        ip link add ${vpnInterface} type wireguard || true
        ip link set ${vpnInterface} netns ${vpnNamespace}

        # Configure WireGuard with Mullvad config
        ip netns exec ${vpnNamespace} wg setconf ${vpnInterface} ${config.age.secrets.mullvad-wg.path}

        # Set the interface address from secret file
        WG_ADDR=$(cat ${config.age.secrets.mullvad-wg-address.path})
        ip netns exec ${vpnNamespace} ip addr add "$WG_ADDR" dev ${vpnInterface} || true
        ip netns exec ${vpnNamespace} ip link set ${vpnInterface} up

        # Route all traffic through WireGuard (default route)
        ip netns exec ${vpnNamespace} ip route add default dev ${vpnInterface} || true

        # DNS configuration (use Mullvad DNS)
        mkdir -p /etc/netns/${vpnNamespace}
        echo "nameserver 10.64.0.1" > /etc/netns/${vpnNamespace}/resolv.conf
      '';
      ExecStop = pkgs.writeShellScript "teardown-wg-vpn" ''
        ip netns exec ${vpnNamespace} ip link del ${vpnInterface} || true
        rm -rf /etc/netns/${vpnNamespace} || true
      '';
    };
  };

  # qBittorrent service running inside the VPN namespace
  systemd.services.qbittorrent = {
    description = "qBittorrent-nox service";
    documentation = ["man:qbittorrent-nox(1)"];
    after = [
      "network.target"
      "wg-${vpnNamespace}.service"
    ];
    requires = ["wg-${vpnNamespace}.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "simple";
      User = user;
      Group = group;
      StateDirectory = "qbittorrent";
      # Run in the VPN namespace
      NetworkNamespacePath = "/var/run/netns/${vpnNamespace}";
      ExecStart = "${pkgs.qbittorrent-nox}/bin/qbittorrent-nox --webui-port=${toString webUiPort}";
      Restart = "on-failure";
      TimeoutStopSec = 1800;
    };
  };

  # Port forwarding from host to namespace for web UI access
  systemd.services.qbittorrent-port-forward = {
    description = "Port forward for qBittorrent Web UI";
    after = ["qbittorrent.service"];
    requires = ["qbittorrent.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "simple";
      Restart = "on-failure";
      ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:${toString webUiPort},fork,reuseaddr EXEC:'${pkgs.iproute2}/bin/ip netns exec ${vpnNamespace} ${pkgs.socat}/bin/socat STDIO TCP\\:127.0.0.1\\:${toString webUiPort}'";
    };
  };

  # Firewall rules for torrent port (forwarded through VPN)
  networking.firewall.allowedTCPPorts = [webUiPort];
  networking.firewall.allowedUDPPorts = [torrentPort];

  services = {
    oauth2-proxy.nginx.virtualHosts = {
      "qbittorrent.nickolaj.com".allowed_groups = ["arr"];
    };
    nginx.virtualHosts = {
      "qbittorrent.nickolaj.com" = mkVirtualHost webUiPort;
    };

    restic.backups.homelab.paths = [
      "/var/lib/qbittorrent"
    ];
  };
})
