{
  flake.modules.homeManager.agents = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.dev.enable (lib.mkMerge [
      {
        # On PATH for pi's extensions/notify.ts; the CLI hooks below use its store path.
        home.packages = lib.optional (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) pkgs.agent-notify;

        # Copilot reads this dir as user hooks, in Claude Code's nested format. Not
        # the module's `settings`: that writes config.json, which Copilot now
        # owns as mutable state (trusted folders); user settings.json is herdr's.
        home.file."${config.programs.github-copilot-cli.configDir}/hooks/agent-notify.json" = lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
          text = builtins.toJSON {
            version = 1;
            hooks.Notification = [
              {
                matcher = "permission_prompt|elicitation_dialog";
                hooks = [
                  {
                    type = "command";
                    command = "${lib.getExe pkgs.agent-notify} Copilot";
                  }
                ];
              }
            ];
          };
        };

        programs.github-copilot-cli = {
          enable = true;
          # Stable node: unstable's would be a second ~130 MB nodejs + icu in the closure.
          package = pkgs.unstable.github-copilot-cli.override {inherit (pkgs) nodejs;};
          # Pulls in programs.mcp.servers (see modules/programs/mcp.nix).
          enableMcpIntegration = true;
          # Shared by every agent; keep it agent-agnostic.
          context = builtins.readFile ./agent-context.md;
          # An attrset, not a linkFarm: the module pathIsDirectory-checks a path, which on a derivation is IFD.
          skills = config.fireproof.agents.skills;
          lspServers =
            lib.mapAttrs (_: s: {
              inherit (s) command args;
              fileExtensions = s.extensionToLanguage;
            })
            config.fireproof.agents.lspServers;
        };
      }

      (lib.mkIf (config.fireproof.dev.pi.enable || config.fireproof.dev.opencode.enable) {
        # Literal path in pi's agent dir: pi's extensions/tensorx.ts reads it there, and opencode's {file:} expands only `~/`.
        age.secrets.tensorx-api-key = {
          rekeyFile = ../../secrets/tensorx-api-key.age;
          path = "${config.home.homeDirectory}/.pi/agent/tensorx-api-key";
          mode = "0600";
        };
        age.secrets.opencode-go-api-key = {
          rekeyFile = ../../secrets/opencode-go-api-key.age;
          path = "${config.home.homeDirectory}/.pi/agent/opencode-go-api-key";
          mode = "0600";
        };
      })
    ]);
  };
}
