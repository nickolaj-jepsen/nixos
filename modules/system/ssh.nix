{
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (config.fireproof) username;
  inherit (config.fireproof) hostname;
  # Load all public keys from ../../secrets/hosts/*/id_ed25519.pub
  allHosts = lib.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ../../secrets/hosts));
  publicKeys = map (x: builtins.readFile (../../secrets/hosts + ("/" + x) + "/id_ed25519.pub")) allHosts;
  workEnabled = config.fireproof.work.enable;
in {
  age.secrets.ssh-key = {
    rekeyFile = ../../secrets/hosts + ("/" + hostname) + /id_ed25519.age;
    path = "/home/" + username + "/.ssh/id_ed25519";
    mode = "0600";
    owner = username;
  };
  age.secrets.ssh-key-ao = lib.mkIf workEnabled {
    rekeyFile = ../../secrets/ssh-key-ao.age;
    mode = "0600";
    owner = username;
  };

  fireproof.home-manager = {
    home.file.".ssh/id_ed25519.pub".source = ../../secrets/hosts + ("/" + hostname) + "/id_ed25519.pub";
    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;
      settings =
        {
          "*" = {
            IdentityFile = "${config.age.secrets.ssh-key.path}";
            ForwardAgent = true;
            ServerAliveInterval = 60;
            ServerAliveCountMax = 10;
            ControlMaster = "auto";
            ControlPath = "~/.ssh/control-%C";
            ControlPersist = "10m";
          };
          homelab = {
            HostName = "x.nickolaj.com";
            User = "nickolaj";
          };
          minilab = {
            HostName = "10.0.0.7";
            User = "nickolaj";
            ProxyJump = "homelab";
          };
          desktop = {
            HostName = "10.0.0.20";
            User = "nickolaj";
            ProxyJump = "homelab";
          };
        }
        // lib.optionalAttrs workEnabled {
          # Work hostnames definded in ./networking.nix
          "bastion.ao" = {
            User = "nij";
            IdentityFile = "${config.age.secrets.ssh-key-ao.path}";
          };
          "clickhouse.ao" = {
            User = "ubuntu";
            HostName = "51.158.205.48";
            IdentityFile = "${config.age.secrets.ssh-key-ao.path}";
          };
          "flex.ao" = {
            User = "nij";
            HostName = "192.168.2.5";
            ProxyJump = "bastion.ao";
            IdentityFile = "${config.age.secrets.ssh-key-ao.path}";
          };
          "scw.ao" = {
            User = "nij";
            HostName = "51.15.81.1";
            ProxyJump = lib.mkDefault "dev.ao";
            IdentityFile = "${config.age.secrets.ssh-key-ao.path}";
          };
          "dev.ao" = {
            User = "nij";
            HostName = "192.168.2.28";
            ProxyJump = lib.mkDefault "bastion.ao";
            IdentityFile = "${config.age.secrets.ssh-key-ao.path}";
          };
          "staging.ao" = {
            User = "staging";
            HostName = "172.16.2.102";
            ProxyJump = lib.mkDefault "bastion.ao";
            IdentityFile = "${config.age.secrets.ssh-key-ao.path}";
          };
          "mac.ao" = {
            User = "it";
            HostName = "b2c-mac-mini";
          };
        };
    };
  };

  programs.ssh.startAgent = true;
  services.gnome.gcr-ssh-agent.enable = false;

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    settings.KbdInteractiveAuthentication = false;
  };

  systemd.user.services."add-ssh-keys" = lib.mkIf workEnabled {
    description = "Add SSH keys to ssh-agent";
    after = ["network.target" "ssh-agent.service"];
    requires = ["ssh-agent.service"];
    wantedBy = ["default.target"];
    serviceConfig = {
      Type = "oneshot";
      ExecStartPre = ''
        ${pkgs.coreutils}/bin/sleep 5
      '';
      ExecStart = ''
        ${pkgs.openssh}/bin/ssh-add -q ${config.age.secrets.ssh-key-ao.path}
      '';
    };
  };

  users.users.${username}.openssh.authorizedKeys.keys = publicKeys;
}
