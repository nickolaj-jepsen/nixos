# Pi coding agent: pi.nix supplies the home-manager module, the package comes
# from pkgs/pi-coding-agent. The package roster is based on the lazypi catalog
# (https://lazypi.org).
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
  mkExtensions = pkgs: pi:
    pkgs.buildNpmPackage {
      pname = "pi-extensions";
      version = "0";
      src = ./extensions;
      # Reads the lockfile directly: no npmDepsHash to bump when deps change.
      npmDeps = pkgs.importNpmLock {npmRoot = ./extensions;};
      inherit (pkgs.importNpmLock) npmConfigHook;
      nativeBuildInputs = [pkgs.typescript];
      # lib/spellfix links to the Claude Code mod, so the editor and `pi -e`
      # see its core; in the store the link dangles, so the files are copied in.
      postPatch = ''
        rm lib/spellfix
        install -Dm644 ${../claude-code/mods/spellfix/hooks/core.ts} lib/spellfix/hooks/core.ts
        install -Dm644 ${../claude-code/mods/spellfix/types/index.d.ts} lib/spellfix/types/index.d.ts
      '';
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
    pi = pkgs.pi-coding-agent;
    # Instance for this host's palette: pi-background-tasks hardcodes its selection
    # band (see pkgs/pi-packages), so the override keeps it on the theme colors.
    piPackages = pkgs.pi-packages.override {themeColors = config.fireproof.theme.colors;};
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
    # browser tools. The server launches its own Chromium on a throwaway profile,
    # never attaching to a running browser. Throwaway because a session that opens
    # a second one would fight the first over a shared profile. A subagent never
    # loads MCP: its tool allowlist names no `mcp__` tool, and that is what the
    # agent package gates the extension on.
    # extensions/browser-gate.ts asks before its first call each session.
    hasBrowser = config.programs.chromium.enable || (pkgs.stdenv.isDarwin && config.fireproof.desktop.enable);
    chrome-devtools = {
      command = lib.getExe pkgs.chrome-devtools-mcp;
      args =
        [
          "--no-usage-statistics"
          "--no-performance-crux"
          "--isolated"
          # Image tokens scale with pixels; full-size PNGs swamp small context windows.
          "--screenshotFormat=jpeg"
          "--screenshotMaxWidth=1280"
        ]
        # Puppeteer can't find a browser on NixOS unaided; darwin's Homebrew Chrome it finds.
        ++ lib.optional config.programs.chromium.enable "--executablePath=${lib.getExe config.programs.chromium.package}";
    };
    # The roster and pins are pkgs/pi-packages/package.json; its alphabetical
    # order loads the permission system first.
    thirdPartyPackages = piPackages.packageNames;
    # One source string per package, so settings.packages and the children's
    # exclusion list in subagents.json cannot drift.
    packagePath = name: "${piPackages}/node_modules/${name}";
    extensionsPath = mkExtensions pkgs pi;
    # Parsed with pi's own reader: one role the package can't parse stops
    # pi-subagents from loading at all.
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
    # Children keep the router (their models are vm/* virtual models, which
    # only our extensions register) and the permission system, whose
    # `ask` forwards to this session. The UI and process-managing packages have
    # nothing to do in a headless child.
    childExcludedPackages =
      map packagePath (lib.subtractLists ["@gotgenes/pi-permission-system"] thirdPartyPackages);
  in {
    imports = [inputs.pi.homeModules.default];

    config = lib.mkIf config.fireproof.dev.pi.enable {
      programs.pi.coding-agent = {
        enable = true;
        package = pi;
        # agent-context.md is shared by every agent; keep it agent-agnostic.
        # How to delegate is in extensions/codemode-only.ts: these rules reach every
        # child as project context, and a child holds no agent tools.
        rules = ''
          ${builtins.readFile ../agent-context.md}
          ## Worktrees in pi

          - Pi removes the worktree its session was in when it exits, if that worktree is
            clean and has nothing ahead of the default branch, and nobody's cwd is inside
            it. Anything with uncommitted work or unpushed commits is left in place.
          - `/new` inside a worktree moves the session to the primary checkout first and
            asks what to do with the worktree it left; `/back` makes the same move without
            starting a fresh conversation.
        '';
        themes = [theme];
        # Nix-built pi can't self-update; extension-update notices still show.
        environment.PI_SKIP_VERSION_CHECK.value = "1";
        # A path, not the key: extensions/exa.ts reads it, so the key stays out
        # of the environment every tool and MCP server inherits.
        environment.PI_EXA_KEY_FILE.value = config.age.secrets.exa-api-key.path;
        # Spellfix (extensions/spellfix.ts) shares its dictionary with the
        # Claude Code mod. Haiku keeps the one batch call cheap.
        environment.PI_SPELLFIX_HUNSPELL.value = lib.getExe spellChecker;
        environment.PI_SPELLFIX_DICTS.value = lib.concatStringsSep "," fpLib.hunspellLanguages;
        environment.PI_SPELLFIX_PERSONAL.value = fpLib.hunspellPersonalDictionary config;
        environment.PI_SPELLFIX_MODEL.value = "anthropic/claude-haiku-5-5";
        # Session labels (extensions/chrome/identity.ts) go through the router,
        # so they fall through the flash ladder while Go's quota is out.
        environment.PI_IDENTITY_MODEL.value = "vm/flash";
        # The fireproof.agents.lspServers registry, read by extensions/lsp.ts.
        environment.PI_LSP_SERVERS = lib.mkIf (config.fireproof.agents.lspServers != {}) {
          value = toString (pkgs.writeText "pi-lsp-servers.json" (builtins.toJSON config.fireproof.agents.lspServers));
        };
        # Plain background shell only: the default set adds seven more tools, and its
        # `attribution` feature rewrites Anthropic requests and rejects API-key credentials.
        environment.PI_BG_FEATURES.value = "process";
        environment.PI_BG_DISABLE_UPDATE_CHECK.value = "1";
        # $SHELL is fish, which the package won't treat as POSIX. The path skips
        # its /bin/bash probe, which on darwin finds Apple's bash 3.2.
        environment.PI_BG_POSIX_SHELL.value = "bash";
        environment.PI_BG_POSIX_SHELL_PATH.value = lib.getExe pkgs.bash;
        settings = {
          # The model picker's "save as default" reverts at launch; change it here.
          # The kinds and their ladders: docs/models.md.
          defaultProvider = "vm";
          defaultModel = "flash";
          defaultThinkingLevel = "high";
          # The pickers open on these and ctrl+p cycles them; their All tab still
          # lists every model. A default outside the list would start on the first
          # entry instead, so the virtual models lead. Each entry's role:
          # docs/models.md.
          enabledModels =
            [
              "vm/*"
              "anthropic/claude-opus-5-5"
              "anthropic/claude-sonnet-5-5"
              "kimi-coding/k3.1-pro"
              "opencode-go/*"
              # `**`: the ids hold a slash (qwen/…), which a glob `*` doesn't cross.
              "tensorx/**"
            ]
            ++ lib.optional config.fireproof.dev.llm.enable "local/*";
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
          # One line per reasoning run instead of the whole block, and the resting
          # state for the thinking chip on the editor border. alt+t or a click still
          # opens it for a session, but a value written that way is merged away at
          # the next launch, like every other setting here.
          hideThinkingBlock = true;
          # `/tree` opens on my prompts; ctrl+d returns to the default view and
          # ctrl+a shows every entry.
          treeFilterMode = "user-only";
          # OSC 9;4 progress in ghostty's tab, for runs long enough to switch away from.
          terminal.showTerminalProgress = true;
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
          map packagePath thirdPartyPackages
          # own, from ./extensions
          ++ [extensionsPath];
        # Arrays replace wholesale, so `pi config` toggles of built-ins revert at launch.
        settings.extensions = [];
        # Built-in MCP reads ~/.pi/agent/mcp.json, not the shared
        # ~/.config/mcp/mcp.json. Merged at launch: /mcp toggles persist, but a
        # server dropped here stays in the file until removed by hand.
        mcp = let
          # pi rejects the null/empty fields home-manager's option fills in.
          shared = lib.mapAttrs (_: lib.filterAttrs (_: v: v != null && v != {} && v != [])) config.programs.mcp.servers;
          servers = shared // lib.optionalAttrs hasBrowser {inherit chrome-devtools;};
        in
          lib.optionalAttrs (servers != {}) {mcpServers = servers;};
      };

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
            # pi's bundled Go catalog predates K3.1 Pro; declare it until a refresh carries it.
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
            # The plan serves k3.1-pro, which pi's bundled catalog predates too;
            # its `kimi-for-coding` id is K2.8 Preview, not this model.
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
                  # The plan rejects the `developer` role and wants prior reasoning
                  # replayed; without this the entry inherits pi's defaults.
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
            # API credits, not the Max subscription: run /login anthropic and
            # that stored OAuth credential would take precedence over this.
            anthropic.apiKey = "!cat ${config.age.secrets.anthropic-api-key.path}";
            # Only for the Jev classifier gate in extensions/routers.ts; the
            # provider itself is one of pi's built-ins.
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
            # Same catalog opencode reads (../_synthetic-models.nix); each client
            # maps it to its own schema.
            synthetic = {
              baseUrl = "https://api.synthetic.new/openai/v1";
              api = "openai-completions";
              apiKey = "!cat ${config.age.secrets.synthetic-api-key.path}";
              compat = {
                supportsStore = false;
                supportsDeveloperRole = false;
                maxTokensField = "max_tokens";
                supportsStrictMode = false;
              };
              models =
                lib.mapAttrsToList (id: m: let
                  level = effort:
                    if lib.elem effort m.efforts
                    then effort
                    else null;
                in {
                  inherit id;
                  inherit (m) name input;
                  reasoning = true;
                  contextWindow = m.ctx;
                  maxTokens = m.maxOut;
                  # A level the endpoint doesn't accept is null: pi hides it.
                  thinkingLevelMap = {
                    off =
                      if lib.elem "none" m.efforts
                      then "none"
                      else null;
                    minimal = null;
                    low = level "low";
                    medium = level "medium";
                    high = level "high";
                    xhigh = level "xhigh";
                    max = level "max";
                  };
                  cost = {
                    input = m.cost.input;
                    output = m.cost.output;
                    cacheRead = m.cost.cached;
                    cacheWrite = 0;
                  };
                })
                (import ../_synthetic-models.nix);
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
                sendSessionAffinityHeaders = false;
                # Sent as chat_template_kwargs, which llama.cpp merges over the
                # server's --chat-template-kwargs rather than replacing them, so the
                # thinking toggle works per request and the pinned effort survives.
                # Not qwen-chat-template: its preserve_thinking keeps old reasoning
                # in the prompt, which the small windows can't spare.
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

      # Claude Code's keys where pi leaves them free: alt+p and ctrl+l open the
      # labelled model picker (extensions/model-labels.ts), leaving the stock one
      # to /model, and alt+t shows or hides thinking blocks (Claude Code's alt+t
      # turns thinking itself on or off; shift+tab cycles that here). Frees ctrl+s for
      # extensions/stash.ts and ctrl+t for the todo overlay below. pi's conflict
      # check ignores view, so every built-in on a key an extension claims moves,
      # even the picker-only alt+s saves and the /tree filter.
      home.file.".pi/agent/keybindings.json".text = builtins.toJSON {
        "$schema" = "https://pi.dev/schemas/keybindings.schema.json";
        # Reserved keys block an extension's, so the stock picker holds none.
        "app.model.select" = [];
        # Drops WSL's alt+p default, which would win over the picker.
        "app.model.cycleBackward" = ["shift+ctrl+p"];
        "app.thinking.toggle" = "alt+t";
        "app.thinking.save" = "alt+s";
        "app.session.toggleSort" = "alt+s";
        "app.models.save" = "alt+s";
        # Still reachable through the filter cycle.
        "app.tree.filter.noTools" = [];
        # ctrl+l opens the labelled model picker.
        "app.tree.filter.labeledOnly" = [];
        # Unbound by pi: the granular scroll between pageUp and the prompt
        # jumps. alt+<page/arrow> stays clear of zellij's plain alt+<letter>.
        "tui.altScreen.halfPageUp" = "alt+pageUp";
        "tui.altScreen.halfPageDown" = "alt+pageDown";
        "tui.altScreen.lineUp" = "alt+shift+up";
        "tui.altScreen.lineDown" = "alt+shift+down";
        # ctrl+end/ctrl+home are a two-hand reach; a list replaces the default, so
        # keep it. alt+end is also what the scrolling pill advertises.
        "tui.altScreen.top" = ["ctrl+home" "alt+home"];
        "tui.altScreen.bottom" = ["ctrl+end" "alt+end"];
        # Unbound by pi. Plain alt+<key> belongs to zellij's default keybinds.
        "app.session.new" = "alt+shift+n";
        "app.session.resume" = "alt+shift+r";
        "app.session.tree" = "alt+shift+t";
        "app.session.fork" = "alt+shift+f";
      };

      # Claude Code puts the todo checklist on ctrl+t (pi's ctrl+t became alt+t
      # above). rpiv-todo only collapses and expands an overlay that is already
      # showing, so the key does nothing while the list is empty.
      home.file.".config/rpiv-todo/config.json".text = builtins.toJSON {
        collapseKey = "ctrl+t";
        guidance.promptGuidelines = [
          "Use `todo` for work with 3+ steps or when the user hands you a list; skip it for a single trivial or conversational task."
          "Keep exactly one task in_progress: mark it before you start and completed as soon as it is done, never while tests fail or the work is partial."
          ''Every call needs `action`, e.g. {"action":"update","id":3,"status":"completed"}.''
        ];
      };

      # Shorter than the guidance it ships with; the parameter schema can't be overridden.
      home.file.".config/rpiv-ask-user-question/config.json".text = builtins.toJSON {
        guidance = {
          description = ''Ask the user 1-4 structured questions, 2-4 options each, and wait for the answers. A "Type something." row and Esc are added to every question; never author "Other" or "Type something." options. Put a recommended option first and end its label with "(Recommended)". An option's `preview` (markdown in a side pane, single-select only) compares concrete artifacts: mockups, code, diagrams, configs; skip it for plain preferences.'';
          promptGuidelines = [
            "Use ask_user_question when the request is underspecified and you cannot proceed without a decision; put every question in one call instead of several in a row."
            "Option labels are 1-5 words and at most 60 characters, headers at most 16; longer ones are rejected."
          ];
        };
      };

      # Children inherit the parent session's extensions unless excluded here,
      # and each child runs its own copy of them. `/subagents:settings` writes the
      # project file only, so this one can stay read-only.
      home.file.".pi/agent/subagents.json".text = builtins.toJSON {
        # A child that interrupts the parent mid-run competes with the turn that
        # spawned it; its findings ride the completion notice instead.
        midRunUpdates = false;
        excludedExtensionPackages = childExcludedPackages;
      };

      # The fireproof.agents.skills registry, in a user skills dir rather than
      # the module's `skills` (a --skill flag): the agent package builds each child
      # session with its own resource loader, which scans this dir but never
      # sees the main process's flags. The cross-tool Agent Skills dir, not
      # ~/.pi/agent/skills, as one store link: `npx skills add` writes here, and
      # a read-only target makes that fail instead of slipping skills into the prompt.
      home.file.".agents/skills".source = pkgs.linkFarm "agent-skills" config.fireproof.agents.skills;

      home.file.".pi/agent/prompts" = {
        source = ./prompts;
        recursive = true;
      };

      # Subagent roles; general-purpose, Explore and Plan override the package's own.
      home.file.".pi/agent/agents" = {
        source = agentRoles;
        recursive = true;
      };

      # Nix-owned (read-only), so pi's "persist globally" approval won't stick;
      # session approvals still work.
      home.file.".pi/agent/extensions/pi-permission-system/config.json".text = builtins.toJSON {
        # Otherwise bg_run is an ordinary extension tool and skips the bash rules below.
        shellTools.bg_run.commandArgument = "command";
        # extensions/guardian.ts: a model judge that approves an ask your own
        # prompts plainly asked for; anything else still reaches the dialog.
        authorizerChain = ["guardian"];
        # A path whose read/write direction is unproven is checked against both
        # external_directory directions and takes the stricter answer, so every
        # routine reader outside the package's pure-reader core lands on the
        # write ask below. Declaring one proves its operands are reads. Don't
        # declare a core word (cat, grep, sed, …): the core wins and the
        # package warns that the entry is ignored.
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
          # eval and the read-only flake verbs; build and run stay undeclared so
          # their store paths and links still ask.
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
          # Gates bash too, and matches symlink targets as well as the path as
          # typed. Every home-manager secret placed outside secretsDir is denied
          # where it lands; the agenix globs cover secretsDir itself on both
          # platforms, the agenix.d/<gen> dirs its symlinks resolve to, and
          # system secrets under /run/agenix.
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
              # /login and MCP OAuth tokens.
              "~/.pi/agent/auth.json" = "deny";
              "~/.pi/agent/mcp-auth.json" = "deny";
            }
            // lib.listToAttrs (map (secret: lib.nameValuePair secret.path "deny")
              (lib.filter (secret: !lib.hasPrefix config.age.secretsDir secret.path)
                (lib.attrValues config.age.secrets)));
          # Where a write lands is decided here, not by bash text: the package
          # also matches every bash path argument in its absolute spelling, so a
          # pattern can't tell `rm -rf build` from `rm -rf /abs/build`. Covers rm,
          # redirects and the write/edit tools alike. A subagent's ask reaches
          # this session's dialog, naming the child. The cwd root
          # counts as inside, so only `rm * ~*` below catches removing it, and
          # only when typed with ~.
          external_directory_write = let
            roots =
              # The store is read-only; listed so `rm result`, a link resolving
              # into it, doesn't ask.
              # One level into ~/worktrees, so a whole <repo> dir still asks.
              ["/tmp" "~/.local/share/agents" "~/worktrees/*" "/nix/store"];
          in
            {"*" = "ask";}
            // lib.listToAttrs (lib.concatMap (root: [
                (lib.nameValuePair "${root}/*" "allow")
                # The typed spelling is matched too, so `/tmp/../home` would
                # otherwise ride the allow.
                (lib.nameValuePair "${root}/*..*" "ask")
              ])
              roots);
          bash = {
            # Explicit, or the top-level "*" still applies but warns at startup.
            "*" = "allow";
            # Bash rules are last-match-wins and Nix sorts these keys, so the
            # generic allow above stays first and narrower rules follow it.
            # A computed path gets no absolute spelling, so the outside-cwd check
            # above can't see it.
            "rm * $*" = "ask";
            "rm * .*" = "ask";
            # Never produced from a relative argument, so only a typed ~ hits it.
            "rm * ~*" = "ask";
            "rm * /" = "deny";
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
            "gh pr create *" = "ask";
            "gh pr comment *" = "ask";
            "gh pr review *" = "ask";
            "gh issue create *" = "ask";
            "gh issue comment *" = "ask";
          };
        };
      };
    };
  };
}
