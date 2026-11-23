{
  fpLib,
  inputs,
  ...
}: let
  mkExtensions = pkgs: pi: piPackages:
    pkgs.buildNpmPackage {
      pname = "pi-extensions";
      version = "0";
      src = ./extensions;
      npmDeps = pkgs.importNpmLock {npmRoot = ./extensions;};
      inherit (pkgs.importNpmLock) npmConfigHook;
      nativeBuildInputs = [pkgs.typescript];
      buildPhase = ''
        runHook preBuild
        # Type against the pi that runs, not an npm copy: a second copy would
        # duplicate its classes. At runtime pi's own aliases win over these links.
        # Linked after npmConfigHook, whose `npm ci` would prune them.
        # nixpkgs' build leaves the coding-agent at lib/node_modules/pi-monorepo
        # and its dependencies in that package's node_modules, so the scope dir
        # has to be assembled from both halves.
        mkdir -p node_modules/@types node_modules/@earendil-works
        ln -s ${pi}/lib/node_modules/pi-monorepo node_modules/@earendil-works/pi-coding-agent
        for dep in ${pi}/lib/node_modules/pi-monorepo/node_modules/@earendil-works/*; do
          ln -s "$dep" node_modules/@earendil-works/
        done
        ln -s ${pi}/lib/node_modules/pi-monorepo/node_modules/typebox node_modules/
        ln -s ${pi}/lib/node_modules/pi-monorepo/node_modules/@types/node node_modules/@types/
        # The third-party packages pi loads, so an extension uses their published
        # API and a bump that breaks it fails here.
        ln -s ${piPackages}/node_modules/@gotgenes node_modules/
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
  # Used by `just dev-setup` for the editor's node_modules.
  perSystem = {system, ...}: let
    # flake-parts' pkgs has no overlay stack, so import one that does.
    pkgs = import inputs.nixpkgs {
      inherit system;
      overlays = [inputs.self.overlays.default];
    };
  in {
    packages.pi-extensions = mkExtensions pkgs pkgs.pi-coding-agent pkgs.pi-packages;
  };

  flake.modules.homeManager.pi = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.fireproof.dev.pi;
    phoenix = import ../_phoenix-client.nix {inherit config;};
    phoenixTelemetry = "${piPackages}/node_modules/@amaster.ai/pi-telemetry/dist/index.js";
    homeDir = config.home.homeDirectory;
    pi = pkgs.pi-coding-agent;
    piPackages = pkgs.pi-packages;
    spellChecker = fpLib.mkHunspell pkgs;
    theme = pkgs.writeText "fireproof.json" (builtins.toJSON (import ./_theme.nix {
      inherit lib;
      colors = config.fireproof.theme.colors;
    }));
    localModels = (import ../_llm-models.nix).${toString config.fireproof.dev.llm.vramGiB};
    localMaxTokens = 8192;
    # The permission system loads first; the rest stay alphabetical.
    thirdPartyPackages =
      ["@gotgenes/pi-permission-system"]
      ++ lib.remove "@gotgenes/pi-permission-system" piPackages.packageNames;
    # settings.packages and the children's exclusions must match string for string.
    packagePath = name: "${piPackages}/node_modules/${name}";
    extensions = mkExtensions pkgs pi piPackages;
    parentPath = "${extensions}/parent";
    # The agents plugins with a pi half, each its own package. One that doesn't set
    # `agentTools.subagents` in its package.json loads only in the session you started.
    piPlugins = lib.filterAttrs (_: plugin: plugin.pi) inputs.agents.lib.plugins;
    pluginNames = lib.attrNames piPlugins;
    # The built plugin: newer agents flakes build it per system (`lib.pluginsFor pkgs`) and make
    # `lib.plugins.<name>.path` throw; older ones point `path` at the source.
    agentsPlugins = (inputs.agents.lib.pluginsFor or (_: inputs.agents.lib.plugins)) pkgs;
    pluginPath = name: agentsPlugins.${name}.path;
    parentOnlyPlugins = lib.attrNames (lib.filterAttrs (_: plugin: !plugin.subagents) piPlugins);
    # One role pi's reader can't parse stops pi-subagents from loading at all.
    agentRoles = pkgs.runCommand "pi-agent-roles" {nativeBuildInputs = [pkgs.nodejs];} ''
      for role in ${./agents}/*.md; do
        node --input-type=module -e "
          import { readFileSync } from 'node:fs';
          import { parseFrontmatter } from '${pi}/lib/node_modules/pi-monorepo/dist/utils/frontmatter.js';
          const { frontmatter } = parseFrontmatter(readFileSync(process.argv[1], 'utf8'));
          for (const key of ['name', 'description'])
            if (typeof frontmatter[key] !== 'string') throw new Error(process.argv[1] + ': ' + key + ' must be a string');
        " "$role"
      done
      cp -r ${./agents} $out
    '';
    # Children keep core/, the permission system, and model providers.
    childExcludedPackages =
      map packagePath (lib.subtractLists [
          "@commandcode/pi-commandcode-provider"
          "@gotgenes/pi-permission-system"
        ]
        thirdPartyPackages)
      ++ [parentPath]
      ++ map pluginPath parentOnlyPlugins;
    # agent-context.md is shared by every agent; keep it agent-agnostic. Children
    # read these rules too and hold no agent tools, so no delegation how-to here.
    rules = builtins.readFile ../agent-context.md;
    env =
      {
        PI_SKIP_VERSION_CHECK = "1";
        # A path, so the key stays out of every tool's and MCP server's environment.
        PI_EXA_KEY_FILE = config.age.secrets.exa-api-key.path;
        PI_SPELLFIX_HUNSPELL = lib.getExe spellChecker;
        PI_SPELLFIX_DICTS = lib.concatStringsSep "," fpLib.hunspellLanguages;
        PI_SPELLFIX_PERSONAL = fpLib.hunspellPersonalDictionary config;
      }
      // lib.optionalAttrs config.fireproof.dev.ai-usage.enable {
        PI_AI_USAGE_COMMAND = lib.getExe pkgs.ai-usage;
      };
    settings = {
      defaultProvider = "auto";
      defaultModel = "deepseek-v4.1-flash";
      defaultThinkingLevel = "high";
      # A default outside the list starts on the first entry, so the default leads.
      enabledModels =
        [
          # The default: DeepSeek on whichever subscription has more headroom.
          "auto/deepseek-v4.1-flash"
          # ChatGPT plan. The bundled catalog ends at GPT-6.1, so 6.2 comes from
          # the pi.dev catalog overlay and is not pinned in models.json.
          "openai-codex/gpt-6.2-sol"
          "kimi-coding/k3.1-pro"
          "anthropic/claude-sonnet-5-5"
          "openai-codex/gpt-6.2-astra"
          "anthropic/claude-opus-5-5"
        ]
        ++ lib.optional config.fireproof.dev.llm.enable "local/*"
        # `*` holds because no free id has a slash.
        ++ ["opencode-go/*-free"];
      # pi's defaults (reserve 16k, keep 20k) overrun a 32k window.
      compaction.modelOverrides = lib.optionalAttrs config.fireproof.dev.llm.enable (lib.mapAttrs' (id: m:
        lib.nameValuePair "local/${id}" {
          reserveTokens = localMaxTokens;
          keepRecentTokens = lib.min 20000 (m.ctx / 4);
        })
      localModels);
      theme = "fireproof";
      quietStartup = "header";
      collapseChangelog = true;
      hideThinkingBlock = false;
      treeFilterMode = "user-only";
      terminal.showTerminalProgress = true;
      shellCommandPrefix = ''eval "$(${lib.getExe config.programs.direnv.package} export bash 2>/dev/null)"'';
      defaultTools = ["+codemode"];
      # parent/ before core/: handlers chain in package order, which sets the
      # system prompt's section order.
      packages =
        map packagePath thirdPartyPackages
        ++ [parentPath]
        ++ map pluginPath pluginNames
        ++ ["${extensions}/core"];
      # Empty on purpose: arrays replace wholesale, reverting `pi config` toggles.
      extensions = [];
    };

    # pi-work: the personal config by symlink, its own credentials, and GitHub
    # Copilot as its only provider. Command Code's provider and
    # the DeepSeek router are left out: with neither subscription there is
    # nothing to route between.
    workFastModel = "github-copilot/${cfg.work.fastModel}";
    # pi's catalog does not carry these yet: the Copilot API lists them for this
    # account, but neither the bundled catalog nor the pi.dev overlay knows them.
    # `models` entries add them beside the built-in models, which stay (the
    # provider key changes nothing else). Entries replace the Copilot chat request
    # headers, hence the copy on each: without them the API answers 400.
    copilotHeaders = {
      User-Agent = "GitHubCopilotChat/0.35.0";
      Editor-Version = "vscode/1.107.0";
      Editor-Plugin-Version = "copilot-chat/0.35.0";
      Copilot-Integration-Id = "vscode-chat";
    };
    workExtraModel = id: name: cost: {
      inherit id name;
      api = "openai-responses";
      reasoning = true;
      input = ["text" "image"];
      contextWindow = 1050000;
      maxTokens = 128000;
      inherit cost;
      headers = copilotHeaders;
      # What the Copilot API reports for these two, from `reasoning_effort`.
      thinkingLevelMap = {
        off = null;
        minimal = null;
        low = "low";
        medium = "medium";
        high = "high";
        xhigh = "xhigh";
        max = "max";
      };
    };
    workSettings =
      settings
      // {
        defaultProvider = "github-copilot";
        defaultModel = cfg.work.model;
        # The work profile's whole menu, and nothing else the account reaches:
        # one default, one fast, and two to pick by hand.
        enabledModels =
          lib.unique (map (id: "github-copilot/${id}")
            [cfg.work.model cfg.work.fastModel "mai-code-2" "gemini-4-hydrogen"]);
        packages =
          map packagePath (lib.remove "@commandcode/pi-commandcode-provider" thirdPartyPackages)
          ++ [parentPath]
          ++ map pluginPath pluginNames;
      };
    # One edit to the rules, keybindings, theme, roles or permission policy reaches
    # both profiles; models.json, auth.json, sessions and mcp.json stay apart.
    mirror = name:
      lib.mkIf cfg.work.enable {
        source = config.lib.file.mkOutOfStoreSymlink "${homeDir}/.pi/agent/${name}";
      };
    # Every role pins a model from the personal catalogue, which this profile has no
    # credentials for: there they all run on its fast model, where the personal ones
    # run on DeepSeek. The body is untouched.
    workAgentRoles = pkgs.runCommand "pi-work-agent-roles" {nativeBuildInputs = [pkgs.gnused];} ''
      mkdir -p $out
      for role in ${agentRoles}/*.md; do
        sed -E 's|^model:.*|model: ${workFastModel}|' "$role" > "$out/$(basename "$role")"
      done
    '';
    # pi rejects the null/empty fields home-manager's option fills in.
    piServers = lib.mapAttrs (_: lib.filterAttrs (_: v: v != null && v != {} && v != []));
    mcpFile = servers: let
      filtered = piServers servers;
    in
      lib.optionalAttrs (filtered != {}) {mcpServers = filtered;};
    mcp = mcpFile config.programs.mcp.servers;
    # The work-owned servers ride here too, in this profile's own file, so neither
    # reaches the personal agents.
    workMcp = mcpFile (config.programs.mcp.servers // config.fireproof.agents.workMcpServers);
    # Only the two models pi's own catalog is missing; the rest come from it.
    workModels = {
      providers.github-copilot.models = [
        (workExtraModel "mai-code-2" "MAI Code 2" {
          input = 0.5;
          output = 2.5;
          cacheRead = 0.025;
          cacheWrite = 0;
        })
        (workExtraModel "mai-code-2-flash" "MAI Code 2 Flash" {
          input = 0.05;
          output = 0.25;
          cacheRead = 0.005;
          cacheWrite = 0;
        })
      ];
    };
    # A key or server dropped here stays in the file until removed by hand.
    # Rewrites only on a change, so running sessions don't see the file churn.
    merge = name: value:
      lib.optionalString (value != {}) ''
        f="$dir/${name}"
        tmp=$(mktemp "$f.XXXXXX")
        ${lib.getExe pkgs.jq} -s '.[0] * .[1]' <(cat "$f" 2>/dev/null || echo '{}') ${pkgs.writeText "pi-${name}" (builtins.toJSON value)} > "$tmp"
        chmod 600 "$tmp"
        if cmp -s "$tmp" "$f"; then rm "$tmp"; else mv "$tmp" "$f"; fi
      '';
    # Both profiles launch through this: the env and the scratch root are
    # shared, while `dir` and the merged config are the profile's own. It exports
    # `dir`, so the profile pi reads is the one the wrapper just merged into.
    mkWrapper = {
      name,
      dir,
      env,
      settings,
      mcp,
      models ? {},
      launch ? "",
    }:
      pkgs.writeShellScriptBin name ''
        ${lib.concatLines (lib.mapAttrsToList (key: value: "export ${key}=${lib.escapeShellArg value}") env)}
        # Agent temp is this session's directory, aged out by `agent-notes reap`.
        ${lib.optionalString config.fireproof.dev.enable ''TMPDIR=$(${lib.getExe pkgs.agent-notes} tmp "$$") || TMPDIR="''${TMPDIR:-/tmp}"; export TMPDIR''}
        # Export it: pi reads the profile from the same variable, and merging into a
        # directory pi then ignores is how a "second profile" silently becomes the first.
        dir="${dir}"
        export PI_CODING_AGENT_DIR="$dir"
        mkdir -p "$dir"
        ${merge "settings.json" settings}
        ${merge "mcp.json" mcp}
        ${merge "models.json" models}
        ${launch}
        exec ${lib.getExe pi} "$@"
      '';
    # core/telemetry.ts loads the package from PI_PHOENIX_TELEMETRY, so subagent
    # sessions get it too: a `-e` flag dies at the session boundary.
    phoenixLaunch = {
      profile,
      project,
    }:
      lib.optionalString phoenix.enabled ''
        if [ "$dir" = "$HOME/${profile}" ] && [ -s ${lib.escapeShellArg phoenix.path} ] && [ "''${PI_OTEL_DISABLED:-0}" != 1 ]; then
          ${phoenix.clear}
          export PI_PHOENIX_ENDPOINT=${lib.escapeShellArg phoenix.endpoint}
          export PI_PHOENIX_PROJECT=${lib.escapeShellArg project}
          export PI_PHOENIX_KEY_FILE=${lib.escapeShellArg phoenix.path}
          export PI_PHOENIX_TELEMETRY=${lib.escapeShellArg phoenixTelemetry}
        fi
      '';
    wrapper = mkWrapper {
      name = "pi";
      dir = "\${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}";
      inherit env settings mcp;
      launch = phoenixLaunch {
        profile = ".pi/agent";
        project = "pi";
      };
    };
    workWrapper = mkWrapper {
      name = "pi-work";
      dir = "\${PI_CODING_AGENT_DIR:-$HOME/.pi/work}";
      inherit env;
      settings = workSettings;
      mcp = workMcp;
      models = workModels;
      launch = ''
        ${phoenix.clear}
        unset PI_PHOENIX_ENDPOINT PI_PHOENIX_KEY_FILE PI_PHOENIX_PROJECT PI_PHOENIX_TELEMETRY "''${!PI_TELEMETRY_@}"
        ${phoenixLaunch {
          profile = ".pi/work";
          project = "pi-work";
        }}
        export PI_OTEL_DISABLED=1 PI_OTEL_ENABLE=0 OTEL_TRACES_EXPORTER=none
      '';
    };
    # The checkout's extensions in place of the installed ones, with no rebuild, and the agents
    # checkout's plugins in the same way.
    piDev = pkgs.writeShellApplication {
      name = "pi-dev";
      text = ''
        extensions="${config.fireproof.agents.checkout}/modules/programs/pi/extensions"
        plugins="${config.fireproof.agents.devCheckout}/plugins"
        [ -d "$extensions/parent" ] || { echo "pi-dev: no extensions under $extensions" >&2; exit 1; }
        [ -d "$plugins" ] || { echo "pi-dev: no plugins under $plugins (fireproof.agents.devCheckout)" >&2; exit 1; }
        exec pi -ne -e builtin:codemode -e builtin:mcp -e "$extensions/core" -e "$extensions/parent" ${lib.concatMapStringsSep " " (name: ''-e "$plugins/${name}"'') pluginNames} "$@"
      '';
    };
  in {
    config = lib.mkIf config.fireproof.dev.pi.enable {
      home.file.".pi/agent/APPEND_SYSTEM.md".text = rules;
      home.file.".pi/agent/themes/fireproof.json".source = theme;

      home.packages = [wrapper spellChecker piDev] ++ lib.optional cfg.work.enable workWrapper;

      # pi-work's config directory: the personal surfaces by symlink, so one edit
      # reaches both (as claude-work mirrors ~/.claude), and its own roles, which
      # name the one provider it reaches. Not auth.json, and not the personal
      # models.json: the wrapper merges the work profile's own, Copilot only.
      home.file.".pi/work/APPEND_SYSTEM.md" = mirror "APPEND_SYSTEM.md";
      home.file.".pi/work/keybindings.json" = mirror "keybindings.json";
      home.file.".pi/work/subagents.json" = mirror "subagents.json";
      home.file.".pi/work/themes" = mirror "themes";
      home.file.".pi/work/extensions" = mirror "extensions";
      home.file.".pi/work/agents" = lib.mkIf cfg.work.enable {
        source = workAgentRoles;
        recursive = true;
      };

      # Literal path: the wrapper single-quotes it, so a secretsDir spelling stays unexpanded.
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

      home.file.".pi/agent/models.json".text = builtins.toJSON {
        providers =
          {
            # pi's bundled Go catalog predates K3.1 Pro.
            opencode-go = {
              apiKey = "!cat ${config.age.secrets.opencode-go-api-key.path}";
              models = [
                {
                  id = "kimi-k3.1-pro";
                  name = "Kimi K3.1 Pro";
                  reasoning = true;
                  input = ["text" "image"];
                  contextWindow = 1048576;
                  maxTokens = 131072;
                  cost = {
                    input = 2;
                    output = 10;
                    cacheRead = 0.2;
                    cacheWrite = 0;
                  };
                  compat = {
                    supportsStore = false;
                    supportsDeveloperRole = false;
                    supportsStrictMode = true;
                    maxTokensField = "max_tokens";
                  };
                }
              ];
            };
            # pi's bundled `kimi-for-coding` is K2.8 Preview, not this model.
            kimi-coding = {
              apiKey = "!cat ${config.age.secrets.kimi-coding-api-key.path}";
              models = [
                {
                  id = "k3.1-pro";
                  name = "Kimi K3.1 Pro";
                  reasoning = true;
                  input = ["text" "image"];
                  contextWindow = 1048576;
                  maxTokens = 131072;
                  cost = {
                    input = 2;
                    output = 10;
                    cacheRead = 0.2;
                    cacheWrite = 0;
                  };
                  # The plan rejects the `developer` role and wants prior reasoning replayed.
                  compat = {
                    supportsStore = false;
                    supportsDeveloperRole = false;
                    supportsStrictMode = false;
                    supportsReasoningEffort = true;
                    maxTokensField = "max_tokens";
                    thinkingFormat = "openai";
                    requiresReasoningContentOnAssistantMessages = true;
                  };
                  thinkingLevelMap = {
                    off = null;
                    minimal = null;
                    low = "low";
                    medium = null;
                    high = "high";
                    xhigh = null;
                    max = "max";
                  };
                }
              ];
            };
            # The native provider extension supplies Command Code's live model catalog.
            command-code.apiKey = "!cat ${config.age.secrets.command-code-api-key.path}";
            # API credits; a `/login anthropic` OAuth credential would take precedence.
            anthropic.apiKey = "!cat ${config.age.secrets.anthropic-api-key.path}";
            # Built-in provider of classifier models, reached from codemode scripts.
            typesafe.apiKey = "!cat ${config.age.secrets.typesafe-api-key.path}";
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
            local = {
              baseUrl = "http://127.0.0.1:9292/v1";
              api = "openai-completions";
              # Unused by llama-swap, but pi ignores a provider without one.
              apiKey = "local";
              compat = {
                supportsStore = false;
                supportsDeveloperRole = false;
                # llama.cpp drops reasoning_effort; llama-swap pins the depth per entry.
                supportsReasoningEffort = false;
                maxTokensField = "max_tokens";
                supportsStrictMode = false;
                sendSessionAffinityHeaders = false;
                # llama.cpp merges these over the server's kwargs, so the pinned effort survives.
                # Not qwen-chat-template: its preserve_thinking replays old reasoning.
                thinkingFormat = "chat-template";
                chatTemplateKwargs.enable_thinking = {"$var" = "thinking.enabled";};
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

      # pi's conflict check ignores view, so every built-in on a key an extension
      # claims moves, even the picker-only alt+s saves and the /tree filters.
      home.file.".pi/agent/keybindings.json".text = builtins.toJSON {
        "$schema" = "https://pi.dev/schemas/keybindings.schema.json";
        # Where pi and Claude Code share an action, the key follows Claude Code.
        # What it has no equivalent for stays out: chords (ctrl+x enter),
        # ctrl+b, ctrl+e and ctrl+l.
        # ctrl+c stays pi's clear-editor, and its second press within 500ms exits.
        # It cannot also interrupt: the editor checks app.interrupt first, and two
        # interrupts on an empty editor are the double-escape gesture (the tree).
        # Claude Code's copy key is absent on purpose: the terminal binds ctrl+shift+c
        # to copy_to_clipboard, so pi never sees it.
        "app.interrupt" = "escape";
        "app.clear" = "ctrl+c";
        # Claude Code's select:previous/next, minus its plain j/k: those are read
        # before a picker's search field, which would stop accepting them.
        "tui.select.up" = ["up" "ctrl+p"];
        "tui.select.down" = ["down" "ctrl+n"];
        # Claude Code's alt+p next to pi's ctrl+l.
        "app.model.select" = ["alt+p" "ctrl+l"];
        # Drops WSL's alt+p default, which would clash with the picker's.
        "app.model.cycleBackward" = ["shift+ctrl+p"];
        "app.thinking.toggle" = "alt+t";
        "app.thinking.save" = "alt+s";
        "app.session.toggleSort" = "alt+s";
        "app.models.save" = "alt+s";
        "app.tree.filter.noTools" = [];
        "app.tree.filter.labeledOnly" = [];
        # Claude Code pages half a viewport; a full page keeps the ctrl pair.
        "tui.altScreen.halfPageUp" = ["pageUp" "alt+pageUp"];
        "tui.altScreen.halfPageDown" = ["pageDown" "alt+pageDown"];
        "tui.altScreen.pageUp" = "ctrl+pageUp";
        "tui.altScreen.pageDown" = "ctrl+pageDown";
        "tui.altScreen.lineUp" = "alt+shift+up";
        "tui.altScreen.lineDown" = "alt+shift+down";
        # A list replaces the default; the scrolling pill advertises alt+end.
        "tui.altScreen.top" = ["ctrl+home" "alt+home"];
        "tui.altScreen.bottom" = ["ctrl+end" "alt+end"];
        # Plain alt+<letter> belongs to zellij.
        "app.session.new" = "alt+shift+n";
        "app.session.resume" = "alt+shift+r";
        "app.session.tree" = "alt+shift+t";
        "app.session.fork" = "alt+shift+f";
      };

      home.file.".config/rpiv-todo/config.json".text = builtins.toJSON {
        collapseKey = "ctrl+t";
        guidance.promptGuidelines = [
          "Use `todo` for work with 3+ steps or when the user hands you a list; skip it for a single trivial or conversational task."
          "Keep exactly one task in_progress: mark it before you start and completed as soon as it is done, never while tests fail or the work is partial."
        ];
      };

      home.file.".pi/agent/subagents.json".text = builtins.toJSON {
        midRunUpdates = false;
        excludedExtensionPackages = childExcludedPackages;
      };

      # A dir, not --skill flags, which children never see. One read-only link, so
      # `npx skills add` fails instead of slipping skills into the prompt.
      home.file.".agents/skills".source = pkgs.linkFarm "agent-skills" config.fireproof.agents.skills;

      home.file.".pi/agent/agents" = {
        source = agentRoles;
        recursive = true;
      };

      # Its config modal saves yolo and log toggles by renaming over this file; over a
      # store link that leaves a plain file the next activation refuses to clobber.
      # Writable instead, reset to Nix's on activation (modules/base/writable-configs.nix).
      fireproof.writableConfigs.pi-permissions.file = ".pi/agent/extensions/pi-permission-system/config.json";
      home.file.".pi/agent/extensions/pi-permission-system/config.json".text = builtins.toJSON {
        # Otherwise bg_run is an ordinary extension tool and skips the bash rules below.
        shellTools.bg_run.commandArgument = "command";
        # An undeclared reader outside the package's core lands on the write ask
        # below. Declaring a core word (cat, grep, sed, …) is ignored with a warning.
        commandEffects = {
          readlink.effects = "read";
          jq.effects = "read";
          cut.effects = "read";
          du.effects = "read";
          df.effects = "read";
          strings.effects = "read";
          sha256sum.effects = "read";
          # The core leaves it out because -C compiles a magic.mgc.
          file = {
            effects = "read";
            unlessOption = ["-C" "--compile"];
          };
          git = {
            unlessOption = ["--output"];
            subcommands = {
              log = "read";
              show = "read";
              status = "read";
              diff = "read";
              rev-parse = "read";
              rev-list = "read";
              merge-base = "read";
              blame = "read";
              grep = "read";
              ls-files = "read";
              cat-file = "read";
              describe = "read";
              shortlog = "read";
              whatchanged = "read";
              for-each-ref = "read";
              remote.subcommands = {
                show = "read";
                get-url = "read";
              };
            };
          };
          # build and run stay undeclared so their store paths and links still ask.
          nix.subcommands = {
            eval = "read";
            search = "read";
            path-info = "read";
            why-depends = "read";
            show-config = "read";
            flake.subcommands = {
              show = "read";
              metadata = "read";
            };
          };
        };
        permission = {
          "*" = "allow";
          # Also matches symlink targets, hence the agenix.d/<gen> globs.
          path =
            {
              "*.env" = "deny";
              "*.env.*" = "deny";
              "*.env.example" = "allow";
              "*/agenix" = "deny";
              "*/agenix/*" = "deny";
              "*/agenix.d" = "deny";
              "*/agenix.d/*" = "deny";
              "~/.ssh/id_*" = "deny";
              "~/.claude/.credentials.json" = "deny";
              "~/.claude-work/.credentials.json" = "deny";
              "~/.pi/agent/auth.json" = "deny";
              "~/.pi/agent/mcp-auth.json" = "deny";
              "~/.pi/work/auth.json" = "deny";
              "~/.pi/work/mcp-auth.json" = "deny";
            }
            // lib.listToAttrs (map (secret: lib.nameValuePair secret.path "deny")
              (lib.filter (secret: !lib.hasPrefix config.age.secretsDir secret.path)
                (lib.attrValues config.age.secrets)));
          # Bash path args are also matched absolute, so gate write locations here,
          # not in bash rules. The cwd root counts as inside, so a path outside the
          # roots is what asks.
          external_directory_write = let
            roots =
              # /nix/store so `rm result` doesn't ask; ~/worktrees/* so a whole <repo> does.
              ["/tmp" "~/.local/share/agents" "~/.local/state/agents" "~/.local/state/pi-plugin-dev" "~/worktrees/*" "/nix/store"];
          in
            {"*" = "ask";}
            // lib.listToAttrs (lib.concatMap (root: [
                (lib.nameValuePair "${root}/*" "allow")
                # The typed spelling is matched too, so `/tmp/../home` would ride the allow.
                (lib.nameValuePair "${root}/*..*" "ask")
              ])
              roots);
          # Reading your own trees is not a decision worth making; the write
          # direction stays exactly as gated above. The bare root is listed
          # because `<root>/*` misses the directory itself, which is what a `cd`
          # operand names.
          external_directory_read = let
            roots = ["/tmp" "~/.local/share/agents" "~/.local/state/agents" "~/worktrees" "~/dev" "~/.claude" "/var/tmp"];
          in
            lib.listToAttrs (lib.concatMap (root: [
                (lib.nameValuePair root "allow")
                (lib.nameValuePair "${root}/*" "allow")
              ])
              roots);
          bash = {
            # Explicit, or the top-level "*" still applies but warns at startup.
            "*" = "allow";
            # Last match wins and Nix sorts keys: `*` sorts first, so narrower rules win.
            # The projection resolves no variable, so a `$name` path gets no absolute
            # spelling and the write gate never sees it. Only $HOME and $PWD can hide
            # a home-wide delete that way; every other name, and `./x`, is left to the
            # write gate, which already asks outside its roots.
            "rm * $HOME*" = "ask";
            "rm * \${HOME}*" = "ask";
            "rm * $PWD*" = "ask";
            "rm * /" = "deny";
            "rm -rf /" = "deny";
            "sudo rm *" = "deny";
            "sudo *" = "ask";
            "git push --force*" = "ask";
            # Mirrored in claude-code's ask list.
            "just switch *" = "ask";
            "just boot *" = "ask";
            "just deploy-remote *" = "ask";
            "just gc *" = "ask";
            "just decrypt *" = "ask";
            "gh pr merge *" = "ask";
            "gh pr create *" = "ask";
            "gh pr comment *" = "ask";
            "gh pr review *" = "ask";
            "gh issue create *" = "ask";
            "gh issue comment *" = "ask";
            # Scaleway: ao-prod carries the same full-access user key as ao-dev, so
            # the profile name and the destructive verbs are the only local gate.
            # SCW_PROFILE= is stripped as an assignment prefix, so an exported
            # profile is not caught here; -p/--profile is.
            "scw * delete*" = "ask";
            "scw * terminate*" = "ask";
            "scw * poweroff*" = "ask";
            "scw * reboot*" = "ask";
            # Print the plaintext key into the transcript, sidestepping the path deny.
            "scw config get secret-key*" = "deny";
            "scw config dump*" = "deny";
          };
        };
      };
    };
  };
}
