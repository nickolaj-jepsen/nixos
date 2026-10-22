# Pi coding agent via pi.nix; the package roster is based on the lazypi
# catalog (https://lazypi.org).
#
# The packages array is authoritative: pi.nix jq-merges settings into
# ~/.pi/agent/settings.json on every launch and arrays replace wholesale —
# imperative `pi install`/`pi remove` edits revert at next start, and entries
# removed here stop loading but leave their download in ~/.pi/agent/{npm,git}.
# npm entries are version-pinned, so `pi update` leaves them alone: bump them
# here (`npm view <pkg> version`); the update bot only covers pkgs/.
#
# Own extensions live in ./extensions, a local pi package: each `.ts` file
# there is one extension. See docs/modules.md.
{
  fpLib,
  inputs,
  ...
}: let
  # node-gyp leaves config.gypi/Makefiles naming the npm-deps cache, python and
  # -dev outputs, which pins ~600 MB of build inputs into the runtime closure.
  mkPi = pkgs:
    inputs.pi.packages.${pkgs.stdenv.hostPlatform.system}.coding-agent.overrideAttrs (old: {
      postInstall =
        (old.postInstall or "")
        + ''
          find $out/lib/node_modules -type d -path '*/build' -prune -print0 \
            | while IFS= read -r -d "" d; do
              [ -e "$d/config.gypi" ] || continue
              find "$d" -mindepth 1 -maxdepth 1 ! -name Release -exec rm -rf {} +
              rm -rf "$d/Release/obj.target" "$d/Release/.deps"
            done
        '';
    });

  mkExtensions = pkgs: pi:
    pkgs.buildNpmPackage {
      pname = "pi-extensions";
      version = "0";
      src = ./extensions;
      # Reads the lockfile directly: no npmDepsHash to bump when deps change.
      npmDeps = pkgs.importNpmLock {npmRoot = ./extensions;};
      inherit (pkgs.importNpmLock) npmConfigHook;
      nativeBuildInputs = [pkgs.typescript];
      buildPhase = ''
        runHook preBuild
        # Type against the pi that runs, not an npm copy: a second copy would
        # duplicate its classes. At runtime pi's own aliases win over these links.
        # Linked after npmConfigHook, whose `npm ci` would prune them.
        mkdir -p node_modules/@types
        ln -s ${pi}/lib/node_modules/@earendil-works node_modules/
        ln -s ${pi}/lib/node_modules/typebox node_modules/
        ln -s ${pi}/lib/node_modules/@types/node node_modules/@types/
        tsc --noEmit
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        cp -r . $out
        runHook postInstall
      '';
    };
in {
  # For `just dev-setup`, which links its node_modules into the repo for the editor.
  perSystem = {pkgs, ...}: {
    packages.pi-extensions = mkExtensions pkgs (mkPi pkgs);
  };

  flake.modules.homeManager.pi = {
    config,
    lib,
    pkgs,
    ...
  }: let
    pi = mkPi pkgs;
    # Shared with the Claude Code spellchecker (lib/default.nix), so a word
    # learned in one agent's picker is known to the other.
    spellChecker = fpLib.mkHunspell pkgs;
  in {
    imports = [inputs.pi.homeModules.default];

    config = lib.mkIf config.fireproof.dev.pi.enable {
      programs.pi.coding-agent = {
        enable = true;
        package = pi;
        # agent-context.md is shared by every agent; keep it agent-agnostic.
        rules = ''
          ${builtins.readFile ../agent-context.md}
          ## Pi

          - `SubagentWorkflow`, `get_subagent_result`, `steer_subagent`, and `kagi_extract` are hidden from the tool list; call them from codemode as `tools.<name>` and read `await describeTool("<name>")` first for their parameters.
          - For a deterministic multi-agent script (Claude Code `Workflow` style), call `tools.SubagentWorkflow` from codemode.
        '';
        # The fireproof.agents.skills registry, linked into one dir.
        skills = [(pkgs.linkFarm "pi-skills" config.fireproof.agents.skills)];
        # Nix-built pi can't self-update; extension-update notices still show.
        environment.PI_SKIP_VERSION_CHECK.value = "1";
        # Read at launch, so the key never lands in the Nix store.
        environment.KAGI_API_KEY.file = config.age.secrets.kagi-api-key.path;
        # Spellfix (extensions/spellfix.ts) shares its dictionary and fix log
        # with the Claude Code mod. Haiku keeps the one batch call cheap.
        environment.PI_SPELLFIX_HUNSPELL.value = lib.getExe spellChecker;
        environment.PI_SPELLFIX_DICTS.value = lib.concatStringsSep "," fpLib.hunspellLanguages;
        environment.PI_SPELLFIX_PERSONAL.value = fpLib.hunspellPersonalDictionary config;
        environment.PI_SPELLFIX_LOG.value = fpLib.spellfixLog config;
        environment.PI_SPELLFIX_MODEL.value = "anthropic/claude-haiku-5-5";
        settings = {
          # The model picker's "save as default" reverts at launch; change it here.
          defaultProvider = "opencode-go";
          defaultModel = "deepseek-v4.1-flash";
          defaultThinkingLevel = "high";
          # Follows the terminal palette and its light/dark switches.
          theme = "system";
          # Keeps the version and key hints; drops the loaded-resource listing.
          quietStartup = "header";
          # Loads the cwd's direnv/nix-direnv env into the bash tool, which
          # otherwise keeps the env pi was launched with. Blocked or missing
          # .envrc files export nothing.
          shellCommandPrefix = ''eval "$(${lib.getExe config.programs.direnv.package} export bash 2>/dev/null)"'';
          # extensions/codemode-only.ts moves the expensive tools behind it.
          defaultTools = ["+codemode"];
        };
        settings.packages = [
          # core
          "npm:@juicesharp/rpiv-ask-user-question@2.13.8"
          "npm:@juicesharp/rpiv-todo@2.13.8"
          # Kagi search/extract; cheaper in context than a full web-access extension.
          "npm:@mjakl/pi-kagi-api@0.1.0"
          # guardrails
          "npm:@gotgenes/pi-permission-system@40.2.0"
          # context diet
          "npm:pi-cache-optimizer@2.8.24"
          # ui
          "npm:@ayulab/pi-rewind@0.4.6"
          # agents
          "npm:@tintinweb/pi-subagents@0.22.0"
          # own, from ./extensions
          "${mkExtensions pkgs pi}"
        ];
        # Arrays replace wholesale, so `pi config` toggles of built-ins revert at launch.
        settings.extensions = [];
        # Built-in MCP reads ~/.pi/agent/mcp.json, not the shared
        # ~/.config/mcp/mcp.json. Merged at launch, so /mcp toggles persist.
        mcp = lib.optionalAttrs (config.programs.mcp.servers != {}) {
          mcpServers = lib.mapAttrs (name: server:
            # pi rejects the null/empty fields home-manager's option fills in.
              lib.filterAttrs (_: v: v != null && v != {} && v != []) server
              # Figma only accepts OAuth registrations from clients it knows.
              // lib.optionalAttrs (name == "figma") {oauth.clientName = "Claude Code";})
          config.programs.mcp.servers;
        };
      };

      # The extension spawns its own hunspell; keep the package in the profile too
      # so the same dictionaries are available outside pi.
      home.packages = [spellChecker];

      # Literal path: the wrapper single-quotes it, so the default secretsDir
      # spelling would reach `cat` unexpanded. It's a symlink into secretsDir.
      age.secrets.kagi-api-key = {
        rekeyFile = ../../../secrets/kagi-api-key.age;
        path = "${config.home.homeDirectory}/.pi/agent/kagi-api-key";
        mode = "0600";
      };

      age.secrets.anthropic-api-key = {
        rekeyFile = ../../../secrets/anthropic-api-key.age;
        path = "${config.home.homeDirectory}/.pi/agent/anthropic-api-key";
        mode = "0600";
      };

      # Not the module's `models` option — it only writes once, never updates.
      home.file.".pi/agent/models.json".text = builtins.toJSON {
        providers =
          {
            # One secret: Zen and Go share an OpenCode account key. Zen's paid
            # models never reach /model, since extensions/curated-models.ts
            # replaces its catalog.
            opencode.apiKey = "!cat ${config.age.secrets.opencode-go-api-key.path}";
            opencode-go.apiKey = "!cat ${config.age.secrets.opencode-go-api-key.path}";
            # API credits, not the Max subscription: run /login anthropic and
            # that stored OAuth credential would take precedence over this.
            anthropic.apiKey = "!cat ${config.age.secrets.anthropic-api-key.path}";
            tensorx = {
              baseUrl = "https://api.tensorx.ai/v1";
              api = "openai-completions";
              apiKey = "!cat ${config.age.secrets.tensorx-api-key.path}";
              compat = {
                supportsStore = false;
                supportsDeveloperRole = false;
                supportsReasoningEffort = true;
                maxTokensField = "max_tokens";
                supportsStrictMode = false;
                thinkingFormat = "openai";
                sendSessionAffinityHeaders = true;
              };
              models = import ./_tensorx-models.nix;
            };
          }
          // lib.optionalAttrs config.fireproof.dev.llm.enable {
            # Served by llama-swap (modules/programs/llm.nix), which unloads one
            # entry to load the other — switching costs a ~15s reload.
            local = {
              baseUrl = "http://127.0.0.1:9292/v1";
              api = "openai-completions";
              # llama-swap is loopback-only and default-allow; the field still has
              # to be set for pi to treat the provider as configured.
              apiKey = "local";
              compat = {
                supportsStore = false;
                supportsDeveloperRole = false;
                # llama.cpp drops top-level reasoning_effort (upstream PR #26941);
                # the depth is pinned server-side per llama-swap entry instead.
                supportsReasoningEffort = false;
                maxTokensField = "max_tokens";
                supportsStrictMode = false;
                thinkingFormat = "deepseek";
                sendSessionAffinityHeaders = false;
                # Merges with the server's --chat-template-kwargs rather than
                # replacing it, so the thinking toggle works and effort survives.
                chatTemplateArgs.enable_thinking = {"$var" = "thinking.enabled";};
              };
              models =
                lib.mapAttrsToList (id: m: {
                  inherit id;
                  inherit (m) name;
                  reasoning = true;
                  # mmproj isn't loaded — no VRAM left for the vision tower.
                  input = ["text"];
                  contextWindow = m.ctx;
                  maxTokens = 8192;
                  cost = {
                    input = 0;
                    output = 0;
                    cacheRead = 0;
                    cacheWrite = 0;
                  };
                })
                (import ../_llm-models.nix).${toString config.fireproof.dev.llm.vramGiB};
            };
          };
      };

      # Frees ctrl+s for extensions/stash.ts. These only act in pickers, but pi's
      # conflict check ignores view and would warn at every startup.
      home.file.".pi/agent/keybindings.json".text = builtins.toJSON {
        "app.thinking.save" = "alt+s";
        "app.session.toggleSort" = "alt+s";
        "app.models.save" = "alt+s";
      };

      # Compact roughly halves Agent's declaration. `/agents` writes project
      # settings only, so this file can stay read-only.
      home.file.".pi/agent/subagents.json".text = builtins.toJSON {
        toolDescriptionMode = "compact";
        # Subagent spend is otherwise missing from the footer and /cost.
        reportUsage = true;
        # Auto stands down if another extension provides a workflow tool.
        workflowsEnabled = true;
      };

      # Nix-owned (read-only), so pi's "persist globally" approval won't stick;
      # session approvals still work.
      home.file.".pi/agent/extensions/pi-permission-system/config.json".text = builtins.toJSON {
        permission = {
          "*" = "allow";
          # Gates bash too, and matches symlink targets, so the agenix-backed
          # ~/.ssh keys and ~/.pi/agent/*-api-key are covered. `agenix*` also catches
          # the agenix.d/<gen> dirs the /run/agenix symlinks resolve to.
          path = {
            "*.env" = "deny";
            "*.env.*" = "deny";
            "*.env.example" = "allow";
            "/run/agenix*" = "deny";
            "/run/user/*/agenix*" = "deny";
            "~/.ssh/id_*" = "deny";
            "~/.claude/.credentials.json" = "deny";
            "~/.claude-work/.credentials.json" = "deny";
          };
          bash = {
            # Explicit, or the top-level "*" still applies but warns at startup.
            "*" = "allow";
            "rm -rf /" = "deny";
            "sudo rm *" = "deny";
            "rm -rf *" = "ask";
            "sudo *" = "ask";
            "git push --force*" = "ask";
            # Mirrors claude-code's ask list: these touch the live system or the outside world.
            "just switch *" = "ask";
            "just boot *" = "ask";
            "just home-switch *" = "ask";
            "just darwin-switch *" = "ask";
            "just deploy-remote *" = "ask";
            "just bootstrap-flash *" = "ask";
            "just gc *" = "ask";
            # Prints plaintext secrets to the transcript.
            "just decrypt *" = "ask";
            "gh pr merge *" = "ask";
          };
        };
      };
    };
  };
}
