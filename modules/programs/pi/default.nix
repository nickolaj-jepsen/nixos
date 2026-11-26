{
  fpLib,
  inputs,
  ...
}: let
  mkExtensions = pkgs: pi:
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
        tsc --noEmit
        node --experimental-strip-types --test parent/*.test.ts parent/lib/*.test.ts parent/chrome/*.test.ts parent/herdr/*.test.*
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
    packages.pi-extensions = mkExtensions pkgs pkgs.pi-coding-agent;
  };

  flake.modules.homeManager.pi = {
    config,
    lib,
    pkgs,
    ...
  }: let
    phoenix = import ../_phoenix-client.nix {inherit config;};
    phoenixTelemetry = "${piPackages}/node_modules/@amaster.ai/pi-telemetry/dist/index.js";
    pi = pkgs.pi-coding-agent;
    piPackages = pkgs.pi-packages;
    spellChecker = fpLib.mkHunspell pkgs;
    theme = pkgs.writeText "fireproof.json" (builtins.toJSON (import ./_theme.nix {
      inherit lib;
      colors = config.fireproof.theme.colors;
    }));
    localModels = (import ../_llm-models.nix).${toString config.fireproof.dev.llm.vramGiB};
    localMaxTokens = 8192;
    thirdPartyPackages = piPackages.packageNames;
    # Load the pinned npm tree as local packages; startup never installs dependencies.
    packagePath = name: "${piPackages}/node_modules/${name}";
    extensions = mkExtensions pkgs pi;
    # A stable package path lets /reload pick up a rebuilt parent integration.
    parentPath = "${config.xdg.configHome}/pi/extensions/parent";
    # What this generation pins, from the flake input (agent-skills.nix builds every half).
    updates = config.fireproof.agents.updates;
    baselinePlugins = updates.baseline.plugins;
    # Every plugin loads in the main session. Durable agents get only the
    # headless-safe tool packages explicitly shared with their tool twin.
    piPlugins = lib.filterAttrs (_: plugin: plugin.pi != null) baselinePlugins;
    pluginNames = lib.attrNames piPlugins;
    pluginPath = name:
      assert lib.assertMsg (piPlugins ? claude-peers) "Update the agents input to a revision containing claude-peers before using this Pi configuration.";
        piPlugins.${name}.pi;
    # A published snapshot replaces a pinned path at launch and on reload (agents-refresh);
    # nothing links the checkout, and no build runs at startup.
    # Validate against the pinned plugin's actual parser: unknown legacy keys
    # silently drop profiles at runtime, which could cause expensive inheritance.
    agentRoles = pkgs.runCommand "pi-agent-profiles" {nativeBuildInputs = [pkgs.nodejs];} ''
      node --input-type=module <<'JS'
      import { readdirSync } from 'node:fs';
      import { createJiti } from '${pi}/lib/node_modules/pi-monorepo/node_modules/jiti/lib/jiti.mjs';
      const jiti = createJiti(import.meta.url, {
        alias: { '@earendil-works/pi-coding-agent': '${pi}/lib/node_modules/pi-monorepo/dist/index.js' },
        fsCache: false,
      });
      const { parseProfileFile } = await jiti.import('${piPackages}/node_modules/pi-agents/src/catalog/profiles.ts');
      const names = new Set();
      const tools = new Set(['read', 'bash', 'edit', 'write', 'grep', 'find', 'ls', 'codemode']);
      for (const file of readdirSync('${./agents}')) {
        if (!file.endsWith('.md')) continue;
        const profile = parseProfileFile('${./agents}/' + file, 'user');
        if (typeof profile === 'string') throw new Error(file + ': ' + profile);
        if (names.has(profile.name)) throw new Error('Duplicate profile: ' + profile.name);
        names.add(profile.name);
        if (!profile.tools?.length || profile.tools.some(tool => !tools.has(tool)))
          throw new Error(file + ': unsupported built-in tool');
        const expected = profile.name === 'expert' ? 'openai-codex/gpt-6.1-sol' : 'auto/deepseek-v4.1-flash';
        if (profile.model !== expected || profile.spawn !== false)
          throw new Error(file + ': model must be explicit and nested delegation disabled');
      }
      if ([...names].sort().join(',') !== 'expert,researcher,reviewer,verifier,worker')
        throw new Error('Unexpected profile roster');
      JS
      cp -r ${./agents} $out
    '';
    # Browser automation over CDP, driven through bash. `agent-browser install`
    # fetches a Chrome for Testing that NixOS can't run, so Linux points it at
    # nixpkgs' Chromium (the desktop's own, when chromium is enabled); macOS finds
    # Google Chrome in /Applications.
    agentBrowser = pkgs.symlinkJoin {
      name = "agent-browser";
      paths = [pkgs.unstable.agent-browser];
      nativeBuildInputs = [pkgs.makeWrapper];
      postBuild = lib.optionalString pkgs.stdenv.isLinux ''
        wrapProgram $out/bin/agent-browser \
          --set-default AGENT_BROWSER_EXECUTABLE_PATH ${lib.getExe pkgs.unstable.chromium}
      '';
    };
    # Pi-only: Claude Code has its own browser tools. The stub tells the agent to
    # `npm i -g` and `agent-browser install`; both are wrong here.
    agentBrowserSkill = pkgs.runCommand "agent-browser-skill" {} ''
      mkdir $out
      sed '/^Install: /d' ${agentBrowser}/skills/agent-browser/SKILL.md > $out/SKILL.md
    '';
    # Shared behavior stays agent-agnostic. Delegation policy lives in parent/
    # rather than in the durable agents' own system prompts.
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
      // lib.optionalAttrs config.fireproof.desktop.enable {
        PI_HERDR_HC = lib.getExe' pkgs.unstable.herdr-core "hc";
        PI_BG_HERDR_HC = lib.getExe' pkgs.unstable.herdr-core "hc";
      }
      // lib.optionalAttrs config.fireproof.dev.ai-usage.enable {
        PI_AI_USAGE_COMMAND = lib.getExe pkgs.ai-usage;
      }
      # fireproof.agents.updates: the upstream bridge runs AGENTS_REFRESH
      # before it reloads, so a published path becomes what this session loads. AGENTS_PROFILE
      # (the profile dir) is exported below, once the wrapper knows it.
      // lib.optionalAttrs updates.enable ({
          AGENTS_UPDATES_ENABLED = "1";
          AGENTS_HARNESS = "pi";
          AGENTS_REFRESH = lib.getExe updates.helper;
          AGENTS_SKILL_EXTRAS = "${updates.extraSkillsFile}";
        }
        // updates.env);
    settings = {
      defaultProvider = "openai-codex";
      defaultModel = "gpt-6.1-sol";
      defaultThinkingLevel = "medium";
      # Keyed provider/id; pi applies it on startup and on every model switch.
      modelThinkingLevels."auto/deepseek-v4.1-flash" = "high";
      # A default outside the list starts on the first entry, so the default leads.
      enabledModels =
        [
          # The default, on the ChatGPT plan.
          "openai-codex/gpt-6.1-sol"
          # DeepSeek on whichever subscription has more headroom.
          "auto/deepseek-v4.1-flash"
          # The bundled catalog ends at GPT-6.1, so 6.2 comes from the pi.dev
          # catalog overlay and is not pinned in models.json.
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
      piAgents = {
        maxWorkingAgents = 6;
        retentionDays = 30;
        # Twins never prompt a model: share tools, not the model router or telemetry.
        twinExtensions = map pluginPath (lib.filter (name: builtins.elem name ["exa" "docfix"]) pluginNames);
      };
      # parent/ before core/: handlers chain in package order, which sets the
      # system prompt's section order.
      packages =
        map packagePath thirdPartyPackages
        ++ [parentPath]
        ++ map pluginPath pluginNames
        ++ ["${extensions}/core"]
        ++ lib.optional updates.enable "${updates.package}/share/agents-updates/pi";
      # Empty on purpose: arrays replace wholesale, reverting `pi config` toggles.
      extensions = [];
    };

    # pi rejects the null/empty fields home-manager's option fills in.
    piServers = lib.mapAttrs (_: lib.filterAttrs (_: v: v != null && v != {} && v != []));
    mcpFile = servers: let
      filtered = piServers servers;
    in
      lib.optionalAttrs (filtered != {}) {mcpServers = filtered;};
    mcp = mcpFile config.programs.mcp.servers;
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
    # Both profiles launch through this: the env is shared, while
    # `dir` and the merged config are the profile's own. It exports `dir`, so the profile pi reads is the one the wrapper just merged into.
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
        # Export it: pi reads the profile from the same variable, and merging into a
        # directory pi then ignores is how a "second profile" silently becomes the first.
        dir="${dir}"
        export PI_CODING_AGENT_DIR="$dir"
        mkdir -p "$dir"
        ${merge "settings.json" settings}
        ${merge "mcp.json" mcp}
        ${merge "models.json" models}
        ${launch}
        ${lib.optionalString updates.enable ''
          # The managed entries of $dir/settings.json (skill resources, packages, twin tools)
          # become what `agents update` published, so this start — and a later reload, which
          # re-reads the file — loads the published store paths. Nothing is built or linked
          # from a checkout, and the skill paths are canonical, not a shared directory.
          export AGENTS_PROFILE="$dir"
          ${lib.getExe updates.helper} || echo "agents updates: could not apply the published paths" >&2
          ${lib.getExe updates.cli} check >&2 || true
        ''}
        exec ${lib.getExe pi} "$@"
      '';
    # The personal profile loads telemetry from core/. Its pi-agents event bridge
    # traces child lifecycles; detailed child generation/tool tracing is deferred.
    phoenixLaunch = profile:
      lib.optionalString phoenix.enabled ''
        if [ "$dir" = "$HOME/${profile}" ] && [ -s ${lib.escapeShellArg phoenix.path} ] && [ "''${PI_OTEL_DISABLED:-0}" != 1 ]; then
          ${phoenix.clear}
          export PI_PHOENIX_ENDPOINT=${lib.escapeShellArg phoenix.endpoint}
          export PI_PHOENIX_PROJECT=pi
          export PI_PHOENIX_KEY_FILE=${lib.escapeShellArg phoenix.path}
          export PI_PHOENIX_TELEMETRY=${lib.escapeShellArg phoenixTelemetry}
        fi
      '';
    wrapper = mkWrapper {
      name = "pi";
      dir = "\${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}";
      inherit env settings mcp;
      launch = phoenixLaunch ".pi/agent";
    };
  in {
    config = lib.mkIf config.fireproof.dev.pi.enable {
      home.file.".pi/agent/APPEND_SYSTEM.md".text = rules;
      home.file.".pi/agent/themes/fireproof.json".source = theme;

      home.packages = [wrapper spellChecker agentBrowser];
      xdg.configFile."pi/extensions/parent".source = "${extensions}/parent";

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

      # The pinned registry, read-only, so `npx skills add` fails instead of slipping skills
      # into the prompt. fireproof.agents.updates then lists the effective skill store paths
      # in settings.json and excludes this directory's copies by name, so a publication reaches
      # the next launch or reload without a directory anything has to rewrite.
      home.file.".agents/skills".source = pkgs.linkFarm "agent-skills" (config.fireproof.agents.skills // {agent-browser = agentBrowserSkill;});

      home.file.".pi/agent/agents" = {
        source = agentRoles;
        recursive = true;
      };
    };
  };
}
