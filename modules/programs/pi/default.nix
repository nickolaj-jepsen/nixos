# Pi coding agent via pi.nix; the package roster is based on the lazypi
# catalog (https://lazypi.org).
#
# The packages array is authoritative: pi.nix jq-merges settings into
# ~/.pi/agent/settings.json on every launch and arrays replace wholesale —
# imperative `pi install`/`pi remove` edits revert at next start, and entries
# removed here stop loading but leave their download in ~/.pi/agent/{npm,git}.
# Third-party packages are Nix-built (pkgs/pi-packages) and listed as local
# paths, so pi never runs npm and `pi update` has nothing to reconcile.
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
    # Static flexoki theme; see _theme.nix for why `system` isn't used.
    theme = pkgs.writeText "fireproof.json" (builtins.toJSON (import ./_theme.nix {
      inherit lib;
      colors = config.fireproof.theme.colors;
    }));
    # llama-swap's entries for this host's VRAM tier (modules/programs/llm.nix).
    localModels = (import ../_llm-models.nix).${toString config.fireproof.dev.llm.vramGiB};
    localMaxTokens = 8192;
    # Pi-only, not in the shared programs.mcp registry: Claude Code has its own
    # browser tools. The server launches its own Chromium on a dedicated profile
    # (~/.cache/chrome-devtools-mcp), never attaching to a running browser.
    # extensions/browser-gate.ts asks before its first call each session.
    hasBrowser = config.programs.chromium.enable || (pkgs.stdenv.isDarwin && config.fireproof.desktop.enable);
    chrome-devtools = {
      command = lib.getExe pkgs.chrome-devtools-mcp;
      args =
        [
          "--no-usage-statistics"
          "--no-performance-crux"
          # Image tokens scale with pixels; full-size PNGs swamp small context windows.
          "--screenshotFormat=jpeg"
          "--screenshotMaxWidth=1280"
        ]
        # Puppeteer can't find a browser on NixOS unaided; darwin's Homebrew Chrome it finds.
        ++ lib.optional config.programs.chromium.enable "--executablePath=${lib.getExe config.programs.chromium.package}";
    };
    # Load order and why each is here; the pins live in
    # pkgs/pi-packages/package.json, and the assertion below keeps the two
    # rosters equal.
    thirdPartyPackages = [
      # core
      "@juicesharp/rpiv-ask-user-question"
      "@juicesharp/rpiv-todo"
      # guardrails
      "@gotgenes/pi-permission-system"
      # context diet
      "pi-cache-optimizer"
      # ui
      "@ayulab/pi-rewind"
      # agents
      "@tintinweb/pi-subagents"
      # long builds/tests without blocking the turn
      "pi-background-tasks"
    ];
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

          - `SubagentWorkflow`, `get_subagent_result`, and `steer_subagent` are hidden from the tool list; call them from codemode as `tools.<name>` and read `await describeTool("<name>")` first for their parameters.
          - For a deterministic multi-agent script (Claude Code `Workflow` style), call `tools.SubagentWorkflow` from codemode.
          - When `bg_status`, `bg_logs` or `bg_kill` is missing from your tool list, call it from codemode, or `read` the output path `bg_run` returned.
        '';
        # The fireproof.agents.skills registry, linked into one dir.
        skills = [(pkgs.linkFarm "pi-skills" config.fireproof.agents.skills)];
        themes = [theme];
        # Nix-built pi can't self-update; extension-update notices still show.
        environment.PI_SKIP_VERSION_CHECK.value = "1";
        # Read at launch, so the key never lands in the Nix store.
        environment.EXA_API_KEY.file = config.age.secrets.exa-api-key.path;
        # Spellfix (extensions/spellfix.ts) shares its dictionary and fix log
        # with the Claude Code mod. Haiku keeps the one batch call cheap.
        environment.PI_SPELLFIX_HUNSPELL.value = lib.getExe spellChecker;
        environment.PI_SPELLFIX_DICTS.value = lib.concatStringsSep "," fpLib.hunspellLanguages;
        environment.PI_SPELLFIX_PERSONAL.value = fpLib.hunspellPersonalDictionary config;
        environment.PI_SPELLFIX_LOG.value = fpLib.spellfixLog config;
        environment.PI_SPELLFIX_MODEL.value = "anthropic/claude-haiku-5-5";
        # You should know (extensions/you-should-know.ts) forks the session model,
        # so a check is a cache read of the main request; PI_YSK_MODEL routes it
        # elsewhere and gives that up. A local session must not check at all:
        # llama-swap has one GPU, and the check would queue ahead of the turn.
        environment.PI_YSK_SKIP_PROVIDERS.value = "local";
        # The fireproof.agents.lspServers registry, read by extensions/lsp.ts.
        environment.PI_LSP_SERVERS = lib.mkIf (config.fireproof.agents.lspServers != {}) {
          value = toString (pkgs.writeText "pi-lsp-servers.json" (builtins.toJSON config.fireproof.agents.lspServers));
        };
        # Plain background shell only: the default set adds seven more tools, and its
        # `attribution` feature rewrites Anthropic requests and rejects API-key credentials.
        environment.PI_BG_FEATURES.value = "process";
        environment.PI_BG_DISABLE_UPDATE_CHECK.value = "1";
        # $SHELL is fish, which the package won't treat as POSIX.
        environment.PI_BG_POSIX_SHELL.value = "bash";
        settings = {
          # The model picker's "save as default" reverts at launch; change it here.
          defaultProvider = "opencode-go";
          defaultModel = "deepseek-v4.1-flash";
          defaultThinkingLevel = "high";
          # The defaults (reserve 16k, keep 20k) overrun a 32k window: compaction would
          # start at 16k, with the system prompt and tools already taking ~9k of it.
          compaction.modelOverrides = lib.optionalAttrs config.fireproof.dev.llm.enable (lib.mapAttrs' (id: m:
            lib.nameValuePair "local/${id}" {
              reserveTokens = localMaxTokens;
              keepRecentTokens = lib.min 20000 (m.ctx / 4);
            })
          localModels);
          # Pinned, not `system`, so the accent is the desktop accent.
          theme = "fireproof";
          # Keeps the version and key hints; drops the loaded-resource listing.
          quietStartup = "header";
          # Loads the cwd's direnv/nix-direnv env into the bash tool, which
          # otherwise keeps the env pi was launched with. Blocked or missing
          # .envrc files export nothing.
          shellCommandPrefix = ''eval "$(${lib.getExe config.programs.direnv.package} export bash 2>/dev/null)"'';
          # extensions/codemode-only.ts moves the expensive tools behind it.
          defaultTools = ["+codemode"];
        };
        # Local paths: pi loads the Nix-built tree as-is (see
        # pkgs/pi-packages for how the npm dependencies get there).
        settings.packages =
          map (name: "${pkgs.pi-packages}/node_modules/${name}") thirdPartyPackages
          # own, from ./extensions
          ++ ["${mkExtensions pkgs pi}"];
        # Arrays replace wholesale, so `pi config` toggles of built-ins revert at launch.
        settings.extensions = [];
        # Built-in MCP reads ~/.pi/agent/mcp.json, not the shared
        # ~/.config/mcp/mcp.json. Merged at launch, so /mcp toggles persist.
        mcp = let
          shared = lib.mapAttrs (name: server:
            # pi rejects the null/empty fields home-manager's option fills in.
              lib.filterAttrs (_: v: v != null && v != {} && v != []) server
              # Figma only accepts OAuth registrations from clients it knows.
              // lib.optionalAttrs (name == "figma") {oauth.clientName = "Claude Code";})
          config.programs.mcp.servers;
          servers = shared // lib.optionalAttrs hasBrowser {inherit chrome-devtools;};
        in
          lib.optionalAttrs (servers != {}) {mcpServers = servers;};
      };

      assertions = let
        declared = lib.sort builtins.lessThan thirdPartyPackages;
      in [
        {
          assertion = declared == lib.sort builtins.lessThan pkgs.pi-packages.packageNames;
          message = ''
            The pi package roster in settings.packages and pkgs/pi-packages/package.json disagree.
            Only here: ${lib.concatStringsSep ", " (lib.subtractLists pkgs.pi-packages.packageNames declared)}
            Only in package.json: ${lib.concatStringsSep ", " (lib.subtractLists declared pkgs.pi-packages.packageNames)}
          '';
        }
      ];

      # pi-background-tasks writes task output to <cwd>/.pi/tasks, with no setting to move it.
      programs.git.ignores = [".pi/tasks/"];

      # The extension spawns its own hunspell; keep the package in the profile too
      # so the same dictionaries are available outside pi.
      home.packages = [spellChecker];

      # Literal path: the wrapper single-quotes it, so the default secretsDir
      # spelling would reach `cat` unexpanded. It's a symlink into secretsDir.
      age.secrets.exa-api-key = {
        rekeyFile = ../../../secrets/exa-api-key.age;
        path = "${config.home.homeDirectory}/.pi/agent/exa-api-key";
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
            # No `opencode` (Zen) entry on purpose: its free models are free only
            # inside opencode itself, and the Go subscription covers the paid ones.
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
                  maxTokens = localMaxTokens;
                  cost = {
                    input = 0;
                    output = 0;
                    cacheRead = 0;
                    cacheWrite = 0;
                  };
                })
                localModels;
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
        # Otherwise bg_run is an ordinary extension tool and skips the bash rules below.
        shellTools.bg_run.commandArgument = "command";
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
            # Bash rules are last-match-wins and Nix sorts these keys, so the
            # generic allow above stays first and narrower rules follow it.
            # Relative cleanup is routine; the destructive shapes still prompt.
            "rm * $*" = "ask";
            "rm * .*" = "ask";
            "rm * /" = "deny";
            "rm * /?*" = "ask";
            "rm * /tmp/*" = "allow";
            "rm * /tmp/..*" = "ask";
            "rm * ~*" = "ask";
            "rm -rf /" = "deny";
            "sudo rm *" = "deny";
            "sudo *" = "ask";
            "git push --force*" = "ask";
            # Mirrors claude-code's ask list: these touch the live system or the outside world.
            "just switch *" = "ask";
            "just boot *" = "ask";
            "just deploy-remote *" = "ask";
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
