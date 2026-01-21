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
  age.secrets.forgejo-ssh-key = {
    rekeyFile = ../../secrets/forgejo-ssh-key.age;
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
      matchBlocks =
        {
          "*" = {
            identityFile = "${config.age.secrets.ssh-key.path}";
            forwardAgent = true;
            serverAliveInterval = 60;
            serverAliveCountMax = 10;
          };
          homelab = {
            hostname = "x.nickolaj.com";
            user = "nickolaj";
          };
          "forgejo.nickolaj.com" = {
            hostname = "forgejo.nickolaj.com";
            user = "git";
            identityFile = "${config.age.secrets.forgejo-ssh-key.path}";
          };
        }
        // lib.optionalAttrs workEnabled {
          # Work hostnames definded in ./networking.nix
          "bastion.ao" = {
            user = "nij";
            identityFile = "${config.age.secrets.ssh-key-ao.path}";
          };
          "clickhouse.ao" = {
            user = "ubuntu";
            hostname = "51.158.205.48";
            identityFile = "${config.age.secrets.ssh-key-ao.path}";
          };
          "flex.ao" = {
            user = "nij";
            hostname = "192.168.2.5";
            proxyJump = "bastion.ao";
            identityFile = "${config.age.secrets.ssh-key-ao.path}";
          };
          "scw.ao" = {
            user = "nij";
            hostname = "51.15.81.1";
            proxyJump = lib.mkDefault "dev.ao";
            identityFile = "${config.age.secrets.ssh-key-ao.path}";
          };
          "dev.ao" = {
            user = "nij";
            hostname = "192.168.2.28";
            proxyJump = lib.mkDefault "bastion.ao";
            identityFile = "${config.age.secrets.ssh-key-ao.path}";
          };
          "staging.ao" = {
            user = "staging";
            hostname = "172.16.2.102";
            proxyJump = lib.mkDefault "bastion.ao";
            identityFile = "${config.age.secrets.ssh-key-ao.path}";
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
