{
  config,
  lib,
  pkgs,
  ...
}:
lib.mkIf config.fireproof.homelab.enable (let
  # VPN namespace configuration
  vpnNamespace = "qbittorrent-vpn";
  vpnInterface = "qbt-wg0";

  # Ports
  webUiPort = 8082;
  torrentPort = 51413;
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

        # Set up loopback interface in namespace
        ip netns exec ${vpnNamespace} ip link set lo up
      '';
      ExecStop = pkgs.writeShellScript "destroy-vpn-netns" ''
        ip netns del ${vpnNamespace} || true
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
        # Clean up any existing WireGuard interface first
        ip link del ${vpnInterface} 2>/dev/null || true
        ip netns exec ${vpnNamespace} ip link del ${vpnInterface} 2>/dev/null || true

        # Create WireGuard interface
        ip link add ${vpnInterface} type wireguard
        ip link set ${vpnInterface} netns ${vpnNamespace}

        # Configure WireGuard with Mullvad config
        ip netns exec ${vpnNamespace} wg setconf ${vpnInterface} ${config.age.secrets.mullvad-wg.path}

        # Set the interface address from secret file
        WG_ADDR=$(cat ${config.age.secrets.mullvad-wg-address.path})
        ip netns exec ${vpnNamespace} ip addr add "$WG_ADDR" dev ${vpnInterface}
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
  services.qbittorrent = {
    enable = true;
    user = "media";
    group = "media";
    webuiPort = webUiPort;
    torrentingPort = torrentPort;
    serverConfig = {
      LegalNotice.Accepted = true;
      Preferences = {
        WebUI = {
          Address = "*";
          Port = webUiPort;
        };
        Connection = {
          PortRangeMin = torrentPort;
        };
        Downloads = {
          SavePath = "/mnt/data/torrent";
        };
      };
    };
  };

  # Override the qbittorrent service to run in VPN namespace
  systemd.services.qbittorrent = {
    after = [
      "network.target"
      "wg-${vpnNamespace}.service"
    ];
    requires = ["wg-${vpnNamespace}.service"];
    serviceConfig = {
      # Run in the VPN namespace
      NetworkNamespacePath = "/var/run/netns/${vpnNamespace}";
      # Bind mount the DNS config into the namespace
      BindReadOnlyPaths = [
        "/etc/netns/${vpnNamespace}/resolv.conf:/etc/resolv.conf"
      ];
    };
  };

  # Port forwarding from host to namespace for web UI access
  systemd.services.qbittorrent-port-forward = {
    description = "Port forward for qBittorrent Web UI";
    after = ["qbittorrent.service"];
    requires = ["qbittorrent.service"];
    wantedBy = ["multi-user.target"];
    path = with pkgs; [iproute2 socat];
    serviceConfig = {
      Type = "simple";
      Restart = "on-failure";
      ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:${toString webUiPort},fork,reuseaddr,bind=0.0.0.0 EXEC:'${pkgs.iproute2}/bin/ip netns exec ${vpnNamespace} ${pkgs.socat}/bin/socat STDIO TCP\\:127.0.0.1\\:${toString webUiPort}'";
    };
  };

  # Firewall rules
  networking.firewall.allowedTCPPorts = [webUiPort];
  networking.firewall.allowedUDPPorts = [torrentPort];

  services = {
    oauth2-proxy.nginx.virtualHosts = {
      "qbittorrent.nickolaj.com".allowed_groups = ["arr"];
    };
    nginx.virtualHosts = {
      "qbittorrent.nickolaj.com" = {
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://localhost:${toString webUiPort}";
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
          '';
        };
      };
    };

    restic.backups.homelab.paths = [
      "/var/lib/qbittorrent"
    ];
  };
})
