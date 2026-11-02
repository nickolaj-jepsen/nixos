{
  flake.modules.nixos.agent-hub = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.fireproof.dev.agent-hub;
    forcedKey = host: let
      pub = lib.removeSuffix "\n" (builtins.readFile (../../secrets/hosts + "/${host}/agent-hub-link.pub"));
      # `command=` alone leaves forwarding on, so a stolen key could reach the socket; `restrict`
      # closes it, and a jump host opens just the hops a viewer's ProxyJump takes.
      forwarding = lib.optionalString (cfg.linkJumps != []) (
        "port-forwarding," + lib.concatMapStrings (hop: ''permitopen="${hop}",'') cfg.linkJumps
      );
    in ''restrict,${forwarding}command="${lib.getExe pkgs.agent-hub} attach --control" ${pub}'';
  in {
    config = lib.mkIf cfg.enable {
      users.users.${config.fireproof.username}.openssh.authorizedKeys.keys = map forcedKey cfg.viewers;
    };
  };

  flake.modules.homeManager.agent-hub = {
    config,
    lib,
    pkgs,
    ...
  }: let
    fp = config.fireproof;
    cfg = fp.dev.agent-hub;
    exe = lib.getExe pkgs.agent-hub;
    # Only a niri desktop has windows to focus; elsewhere the hub serves the agents' own TUIs.
    desktop = fp.desktop.enable && pkgs.stdenv.isLinux;
    linked = cfg.remotes != {};
    # A host as `ssh <host>` knows it: its address, user and jump from the login config, if it has
    # an entry there, under what the host card overrides.
    hostOptions = host:
      lib.filterAttrs (key: _: builtins.elem key ["HostName" "User" "ProxyJump"]) (config.programs.ssh.settings.${host}.data or {})
      // (cfg.remotes.${host} or {});
    hostBlock = host:
      lib.concatStringsSep "\n" (
        ["Host ${host}"] ++ lib.mapAttrsToList (key: value: "  ${key} ${toString value}") (hostOptions host)
      );
    remoteHosts = builtins.attrNames cfg.remotes;
    jumps = lib.remove "none" (lib.filter (jump: jump != null) (map (host: (hostOptions host).ProxyJump or null) remoteHosts));
    # Its own config, not the login one: that one's `*` multiplexes every connection, so a link
    # could ride a full login, or a later `ssh host` land in `attach`, and adds the host's full key.
    sshConfig = lib.concatStringsSep "\n" (
      map hostBlock (lib.unique (remoteHosts ++ jumps))
      ++ [
        ''
          Host *
            IdentityFile ${config.age.secrets.agent-hub-link.path}
            IdentitiesOnly yes
            BatchMode yes
            ControlMaster no
            ControlPath none
            ForwardAgent no
            ConnectTimeout 15
            ServerAliveInterval 30
            ServerAliveCountMax 3
        ''
      ]
    );
  in {
    config = lib.mkIf cfg.enable (lib.mkMerge [
      {
        home.packages = [pkgs.agent-hub];
        xdg.configFile."agent-hub/config.json".text = builtins.toJSON ({
            # The bare package, without the wrapper's plugin dirs, for the readings.
            claude = lib.getExe config.programs.claude-code.package;
            # A user unit has no login PATH: working trees and branches for the readings.
            git = lib.getExe pkgs.git;
          }
          // lib.optionalAttrs desktop {
            # The running compositor's IPC, and a user unit has no login PATH.
            niri = lib.getExe pkgs.niri-unstable;
            # What resumes an ended session from the popout, spawned through niri as Mod+Return is.
            terminal = ["ghostty" "--working-directory={cwd}" "-e"];
          }
          // lib.optionalAttrs linked {
            remotes = remoteHosts;
            ssh = lib.getExe pkgs.openssh;
            sshConfig = "${config.xdg.configHome}/agent-hub/ssh_config";
          });
      }

      (lib.mkIf linked {
        age.secrets.agent-hub-link = {
          rekeyFile = ../../secrets/hosts + "/${fp.hostname}/agent-hub-link.age";
          path = "${config.home.homeDirectory}/.ssh/agent_hub_link";
          mode = "0600";
        };
        xdg.configFile."agent-hub/ssh_config".text = sshConfig;
      })

      # Everything but Claude's dialog labels is read back from the registry or the
      # hub's state file, so a restart loses at most a label.
      (lib.mkIf pkgs.stdenv.isLinux {
        systemd.user.services.agent-hub = {
          Unit.Description = "agent-hub, the hub for live coding-agent sessions";
          Service = {
            ExecStart = "${exe} daemon";
            Restart = "always";
            RestartSec = 2;
          };
          Install.WantedBy = ["default.target"];
        };
      })

      (lib.mkIf pkgs.stdenv.isDarwin {
        launchd.agents.agent-hub = {
          enable = true;
          config = {
            ProgramArguments = [exe "daemon"];
            KeepAlive = true;
            RunAtLoad = true;
            StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/agent-hub.log";
          };
        };
      })
    ]);
  };
}
