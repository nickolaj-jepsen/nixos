# ssh-key (nixos-side) IS ~/.ssh/id_ed25519, the runtime identity HM agenix uses to decrypt every other user secret, so it must stay root-placed (can't decrypt itself).
{
  flake.modules.nixos.ssh = {
    config,
    lib,
    ...
  }: let
    inherit (config.fireproof) username hostname;
    allHosts = lib.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ../../secrets/hosts));
    # Skip non-SSH pubkeys (e.g. a pre-deploy darwin host's age placeholder).
    publicKeys =
      lib.filter (lib.hasPrefix "ssh-")
      (map (x: builtins.readFile (../../secrets/hosts + ("/" + x) + "/id_ed25519.pub")) allHosts);
  in {
    age.secrets.ssh-key = {
      rekeyFile = ../../secrets/hosts + ("/" + hostname) + /id_ed25519.age;
      path = "/home/" + username + "/.ssh/id_ed25519";
      mode = "0600";
      owner = username;
    };

    # ssh-agent now lives in the home-manager half (services.ssh-agent) so it
    # covers standalone home hosts too; keep gcr from hijacking SSH_AUTH_SOCK.
    services.gnome.gcr-ssh-agent.enable = false;

    services.openssh = {
      enable = true;
      settings.PasswordAuthentication = false;
      settings.KbdInteractiveAuthentication = false;
    };

    users.users.${username}.openssh.authorizedKeys.keys = publicKeys;
  };

  # darwin: just place the host identity at ~/.ssh so HM-side agenix can decrypt.
  flake.modules.darwin.ssh = {config, ...}: let
    inherit (config.fireproof) username hostname;
  in {
    age.secrets.ssh-key = {
      rekeyFile = ../../secrets/hosts + ("/" + hostname) + /id_ed25519.age;
      path = "/Users/" + username + "/.ssh/id_ed25519";
      mode = "0600";
      owner = username;
    };
  };

  flake.modules.homeManager.ssh = {
    config,
    pkgs,
    lib,
    ...
  }: let
    inherit (config.fireproof) hostname;
    workEnabled = config.fireproof.work.enable;
    identityFile = "${config.home.homeDirectory}/.ssh/id_ed25519";
  in {
    # Explicit absolute path: ~/.ssh/config and the systemd ExecStart below don't reliably expand ${XDG_RUNTIME_DIR}.
    age.secrets.ssh-key-ao = lib.mkIf workEnabled {
      rekeyFile = ../../secrets/ssh-key-ao.age;
      path = "${config.home.homeDirectory}/.ssh/id_ed25519_ao";
      mode = "0600";
    };

    home.file.".ssh/id_ed25519.pub".source = ../../secrets/hosts + ("/" + hostname) + "/id_ed25519.pub";

    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;
      settings =
        {
          "*" = {
            IdentityFile = identityFile;
            ForwardAgent = true;
            # Load keys into the agent on first use — covers darwin, which has no
            # systemd add-ssh-keys service (below).
            AddKeysToAgent = "yes";
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
          "bastion.ao" = {
            User = "nij";
            HostName = lib.mkDefault "62.199.221.53";
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

    # The agent itself (was NixOS programs.ssh.startAgent) — ungated so every
    # host/user gets one, including the standalone home host. Same %t/ssh-agent
    # socket; sets home.sessionVariables.SSH_AUTH_SOCK for shells.
    services.ssh-agent.enable = true;

    # Linux-only: darwin has no systemd, and AddKeysToAgent (above) covers it there.
    systemd.user.services."add-ssh-keys" = lib.mkIf (workEnabled && pkgs.stdenv.isLinux) {
      Unit = {
        Description = "Add SSH keys to ssh-agent";
        After = ["network.target" "ssh-agent.service"];
        Requires = ["ssh-agent.service"];
      };
      Service = {
        Type = "oneshot";
        # The systemd user manager doesn't inherit home.sessionVariables, so point
        # ssh-add at the agent socket explicitly.
        Environment = ["SSH_AUTH_SOCK=%t/ssh-agent"];
        ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
        ExecStart = "${pkgs.openssh}/bin/ssh-add -q ${config.age.secrets.ssh-key-ao.path}";
      };
      Install.WantedBy = ["default.target"];
    };
  };
}
