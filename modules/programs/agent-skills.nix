# Wires nickolaj-jepsen/agents into home-manager: its skills (`lib.skills`) go into the
# fireproof.agents.skills registry, and `fireproof.agents.updates` publishes an explicit
# snapshot of a checkout on demand (`agents update NAME`) instead of linking one live. UI
# artifacts share the same baseline/override selection and ownership-aware deployer. Third
# party skills are registered by their feature leaves instead (e.g. gh-stack in git.nix).
{inputs, ...}: {
  perSystem = {system, ...}: {
    checks.agents-updates = inputs.agents.packages.${system}.agents-updates.tests;
  };

  flake.modules.homeManager.agent-skills = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.fireproof.agents;
    inherit (cfg) updates;
    upstream = inputs.agents.lib;
    # The pinned input's builds for this system. A plugin's `path` is its `dist/`; its Claude
    # half is validated and tested against the claude-code that runs it, which is the
    # unwrapped package (`programs.claude-code.package`), not the wrapper — the wrapper's
    # settings are built from these paths, so using it here would recurse.
    plugins = (upstream.pluginsFor or (_: upstream.plugins)) pkgs;
    claudePlugin = name:
      upstream.mkClaudePlugin {
        inherit pkgs;
        claude-code = config.programs.claude-code.package;
      }
      name;
    pluginNames = lib.attrNames (lib.filterAttrs (_: plugin: plugin.pi || plugin.claude) plugins);
    # What a switch pins: one path per variant, null where the plugin has no such half.
    baselinePlugins = lib.genAttrs pluginNames (name: {
      pi =
        if plugins.${name}.pi
        then plugins.${name}.path
        else null;
      claude =
        if plugins.${name}.claude
        then "${claudePlugin name}"
        else null;
    });
    baseline = {
      revision = inputs.agents.rev or "";
      plugins = baselinePlugins;
      skills = lib.mapAttrs (_: path: "${path}") cfg.skills;
      ui = lib.mapAttrs (_: path: "${path}") updates.ui;
    };
    # Read by `agents`, which builds a published snapshot against this nixpkgs and reports on
    # the pinned revision. AGENTS_CLAUDE is the package mkClaudePlugin runs (the unwrapped
    # one), so a published Claude half is tested the same way the pinned one was. Kept apart
    # from AGENTS_CLI: the CLI's own wrapper exports these, so it cannot point at itself.
    envBase = {
      AGENTS_BASELINE = "${updates.baselineFile}";
      AGENTS_CHECKOUT = cfg.devCheckout;
      AGENTS_NIXPKGS = "${pkgs.path}";
      AGENTS_CLAUDE = "${config.programs.claude-code.package}";
      AGENTS_SYSTEM = pkgs.stdenv.hostPlatform.system;
      XDG_CONFIG_HOME = config.xdg.configHome;
      XDG_STATE_HOME = config.xdg.stateHome;
    };
    # For scripts that call the CLI: baked in, so nothing depends on the caller's PATH or
    # remembering to export the baseline.
    envExports = lib.concatLines (lib.mapAttrsToList (key: value: "export ${key}=${lib.escapeShellArg value}") envBase);
    cliEnv = envBase // {AGENTS_CLI = lib.getExe updates.cli;};
  in {
    options.fireproof.agents = {
      devCheckout = lib.mkOption {
        type = lib.types.str;
        default = "${config.home.homeDirectory}/dev/agents";
        description = "Where nickolaj-jepsen/agents is checked out; `agents update` publishes snapshots from it.";
      };

      updates = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = config.fireproof.dev.enable;
          defaultText = lib.literalExpression "config.fireproof.dev.enable";
          description = ''
            Load agents' pinned plugins and skills, with `agents update NAME` publishing a
            newer snapshot of the checkout's `apps/` or `skills/` for the next launch. Nothing
            links the checkout itself: there is no build at startup. Plugin paths are resolved
            at launch or reload. Claude's skill links are a shared per-profile view, refreshed
            at launch; Pi's skill metadata points directly at immutable snapshots.
          '';
        };

        ui = lib.mkOption {
          type = lib.types.attrsOf lib.types.path;
          default = {};
          internal = true;
          description = "Pinned UI artifacts deployed by the shared agents updater.";
        };

        baselineFile = lib.mkOption {
          type = lib.types.path;
          readOnly = true;
          internal = true;
          default = pkgs.writeText "agents-baseline.json" (builtins.toJSON baseline);
          description = "The pinned revision, plugin, skill and UI paths, as `agents` reads them.";
        };

        baseline = lib.mkOption {
          type = lib.types.attrs;
          readOnly = true;
          internal = true;
          default = baseline;
          description = "baselineFile's content, for the harness modules that load these paths.";
        };

        package = lib.mkOption {
          type = lib.types.package;
          readOnly = true;
          internal = true;
          default = inputs.agents.packages.${pkgs.stdenv.hostPlatform.system}.agents-updates;
          description = "Shared publication tooling and Pi bridge from the pinned agents input.";
        };

        cli = lib.mkOption {
          type = lib.types.package;
          readOnly = true;
          internal = true;
          default = pkgs.writeShellApplication {
            name = "agents";
            runtimeInputs = [updates.package];
            text = ''
              # The pinned baseline and where a snapshot is built from, baked in: `agents`
              # works from any shell, and an activation script needs no environment.
              ${envExports}
              exec ${updates.package}/bin/agents "$@"
            '';
          };
          description = "The `agents` command: update, reset, status, check, resolve and deploy-ui.";
        };

        helper = lib.mkOption {
          type = lib.types.package;
          readOnly = true;
          internal = true;
          default = updates.package.refresh;
          description = ''
            Turns the published state into one profile's skill view and pi settings. pi's
            bridge runs it as AGENTS_REFRESH before it reloads.
          '';
        };

        # Skills the harness leaves generate themselves: pi's agent-browser stub has no
        # registry entry, and Claude Code has its own browser tools.
        extraSkills = lib.mkOption {
          type = lib.types.attrsOf lib.types.path;
          default = {};
          internal = true;
          description = "Skills added to pi's view but not to the registry.";
        };

        extraSkillsFile = lib.mkOption {
          type = lib.types.path;
          readOnly = true;
          internal = true;
          default = pkgs.writeText "agents-extra-skills.json" (builtins.toJSON (lib.mapAttrs (_: path: "${path}") cfg.updates.extraSkills));
          description = "extraSkills as JSON, for the pi refresh helper.";
        };

        env = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          readOnly = true;
          internal = true;
          default = cliEnv;
          description = "The environment `agents` and the refresh helper read.";
        };

        envExports = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          internal = true;
          default = lib.concatLines (lib.mapAttrsToList (key: value: "export ${key}=${lib.escapeShellArg value}") cliEnv);
          description = "env as shell exports, for the scripts this module's consumers write.";
        };
      };
    };

    config = lib.mkMerge [
      # Every agent that installs the registry gets the pinned skills, updates or not.
      {fireproof.agents.skills = inputs.agents.lib.skills;}

      (lib.mkIf updates.enable {
        # Availability of the command is the feature: publishing is what makes an update explicit.
        home.packages = [updates.cli];

        # After the files are written, say when what is published is not what this generation
        # pins. A switch never republishes: that stays an explicit `agents update`.
        home.activation.agentsUpdatesCheck = lib.hm.dag.entryAfter ["writeBoundary"] ''
          ${updates.envExports}
          ${cliEnv.AGENTS_CLI} check || true
        '';
      })
    ];
  };
}
