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
      # parent/lib/spellfix is a symlink to the Claude Code mod; it dangles in the store.
      postPatch = ''
        rm parent/lib/spellfix
        install -Dm644 ${../claude-code/mods/spellfix/hooks/core.ts} parent/lib/spellfix/hooks/core.ts
        install -Dm644 ${../claude-code/mods/spellfix/types/index.d.ts} parent/lib/spellfix/types/index.d.ts
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
    pi = pkgs.pi-coding-agent;
    piPackages = pkgs.pi-packages;
    spellChecker = fpLib.mkHunspell pkgs;
    theme = pkgs.writeText "fireproof.json" (builtins.toJSON (import ./_theme.nix {
      inherit lib;
      colors = config.fireproof.theme.colors;
    }));
    localModels = (import ../_llm-models.nix).${toString config.fireproof.dev.llm.vramGiB};
    localMaxTokens = 8192;
    hasBrowser = config.programs.chromium.enable || (pkgs.stdenv.isDarwin && config.fireproof.desktop.enable);
    chrome-devtools = {
      command = lib.getExe pkgs.chrome-devtools-mcp;
      args =
        [
          "--no-usage-statistics"
          "--no-performance-crux"
          # A shared profile would make a second session fight the first.
          "--isolated"
          "--screenshotFormat=jpeg"
          "--screenshotMaxWidth=1280"
        ]
        # Puppeteer can't find a browser on NixOS unaided; darwin's Homebrew Chrome it finds.
        ++ lib.optional config.programs.chromium.enable "--executablePath=${lib.getExe config.programs.chromium.package}";
    };
    # Alphabetical order loads the permission system first.
    thirdPartyPackages = piPackages.packageNames;
    # settings.packages and the children's exclusions must match string for string.
    packagePath = name: "${piPackages}/node_modules/${name}";
    extensions = mkExtensions pkgs pi piPackages;
    parentPath = "${extensions}/parent";
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
    # Children keep core/ (only its router registers vm/*) and the permission system.
    childExcludedPackages =
      map packagePath (lib.subtractLists ["@gotgenes/pi-permission-system"] thirdPartyPackages)
      ++ [parentPath];
    # agent-context.md is shared by every agent; keep it agent-agnostic. Children
    # read these rules too and hold no agent tools, so no delegation how-to here.
    rules = ''
      ${builtins.readFile ../agent-context.md}
      ## Worktrees in pi

      - `/wt <name>` moves the session into a worktree (creating it if new); `/back`
        moves it to the primary checkout. Neither touches the worktree's contents.
      - Pi never commits, lands, or removes a worktree, including on exit. Use
        explicit `wt sync`, `wt apply`, `wt clean`, or `wt remove` when you choose to.
      - `/new` inside a worktree starts a fresh session in that worktree.
    '';
    env =
      {
        PI_SKIP_VERSION_CHECK = "1";
        # A path, so the key stays out of every tool's and MCP server's environment.
        PI_EXA_KEY_FILE = config.age.secrets.exa-api-key.path;
        PI_SPELLFIX_HUNSPELL = lib.getExe spellChecker;
        PI_SPELLFIX_DICTS = lib.concatStringsSep "," fpLib.hunspellLanguages;
        PI_SPELLFIX_PERSONAL = fpLib.hunspellPersonalDictionary config;
      }
      // lib.optionalAttrs (config.fireproof.agents.lspServers != {}) {
        PI_LSP_SERVERS = toString (pkgs.writeText "pi-lsp-servers.json" (builtins.toJSON config.fireproof.agents.lspServers));
      };
    settings = {
      defaultProvider = "vm";
      defaultModel = "flash";
      defaultThinkingLevel = "high";
      # A default outside the list starts on the first entry, so vm/* leads.
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
      # pi's defaults (reserve 16k, keep 20k) overrun a 32k window.
      compaction.modelOverrides = lib.optionalAttrs config.fireproof.dev.llm.enable (lib.mapAttrs' (id: m:
        lib.nameValuePair "local/${id}" {
          reserveTokens = localMaxTokens;
          keepRecentTokens = lib.min 20000 (m.ctx / 4);
        })
      localModels);
      theme = "fireproof";
      quietStartup = "header";
      hideThinkingBlock = true;
      treeFilterMode = "user-only";
      terminal.showTerminalProgress = true;
      shellCommandPrefix = ''eval "$(${lib.getExe config.programs.direnv.package} export bash 2>/dev/null)"'';
      defaultTools = ["+codemode"];
      # parent/ before core/: handlers chain in package order, which sets the
      # system prompt's section order.
      packages =
        map packagePath thirdPartyPackages
        ++ [parentPath "${extensions}/core"];
      # Empty on purpose: arrays replace wholesale, reverting `pi config` toggles.
      extensions = [];
    };
    mcp = let
      # pi rejects the null/empty fields home-manager's option fills in.
      shared = lib.mapAttrs (_: lib.filterAttrs (_: v: v != null && v != {} && v != [])) config.programs.mcp.servers;
      servers = shared // lib.optionalAttrs hasBrowser {inherit chrome-devtools;};
    in
      lib.optionalAttrs (servers != {}) {mcpServers = servers;};
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
    wrapper = pkgs.writeShellScriptBin "pi" ''
      ${lib.concatLines (lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") env)}
      dir="''${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
      mkdir -p "$dir"
      ${merge "settings.json" settings}
      ${merge "mcp.json" mcp}
      exec ${lib.getExe pi} "$@"
    '';
  in {
    config = lib.mkIf config.fireproof.dev.pi.enable {
      home.file.".pi/agent/APPEND_SYSTEM.md".text = rules;
      home.file.".pi/agent/themes/fireproof.json".source = theme;

      home.packages = [wrapper spellChecker];

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
            # API credits; a `/login anthropic` OAuth credential would take precedence.
            anthropic.apiKey = "!cat ${config.age.secrets.anthropic-api-key.path}";
            # Built-in provider; only the router's Jev gate uses it.
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
        # Reserved keys block an extension's, so the stock picker holds none.
        "app.model.select" = [];
        # Drops WSL's alt+p default, which would win over the picker.
        "app.model.cycleBackward" = ["shift+ctrl+p"];
        "app.thinking.toggle" = "alt+t";
        "app.thinking.save" = "alt+s";
        "app.session.toggleSort" = "alt+s";
        "app.models.save" = "alt+s";
        "app.tree.filter.noTools" = [];
        "app.tree.filter.labeledOnly" = [];
        "tui.altScreen.halfPageUp" = "alt+pageUp";
        "tui.altScreen.halfPageDown" = "alt+pageDown";
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
          ''Every call needs `action`, e.g. {"action":"update","id":3,"status":"completed"}.''
        ];
      };

      home.file.".config/rpiv-ask-user-question/config.json".text = builtins.toJSON {
        guidance = {
          description = ''Ask the user 1-4 structured questions, 2-4 options each, and wait for the answers. A "Type something." row and Esc are added to every question; never author "Other" or "Type something." options. Put a recommended option first and end its label with "(Recommended)". An option's `preview` (markdown in a side pane, single-select only) compares concrete artifacts: mockups, code, diagrams, configs; skip it for plain preferences.'';
          promptGuidelines = [
            "Use ask_user_question when the request is underspecified and you cannot proceed without a decision; put every question in one call instead of several in a row."
            "Option labels are 1-5 words and at most 60 characters, headers at most 16; longer ones are rejected."
          ];
        };
      };

      home.file.".pi/agent/subagents.json".text = builtins.toJSON {
        midRunUpdates = false;
        excludedExtensionPackages = childExcludedPackages;
      };

      # A dir, not --skill flags, which children never see. One read-only link, so
      # `npx skills add` fails instead of slipping skills into the prompt.
      home.file.".agents/skills".source = pkgs.linkFarm "agent-skills" config.fireproof.agents.skills;

      home.file.".pi/agent/prompts" = {
        source = ./prompts;
        recursive = true;
      };

      home.file.".pi/agent/agents" = {
        source = agentRoles;
        recursive = true;
      };

      home.file.".pi/agent/extensions/pi-permission-system/config.json".text = builtins.toJSON {
        # Otherwise bg_run is an ordinary extension tool and skips the bash rules below.
        shellTools.bg_run.commandArgument = "command";
        authorizerChain = ["guardian"];
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
            }
            // lib.listToAttrs (map (secret: lib.nameValuePair secret.path "deny")
              (lib.filter (secret: !lib.hasPrefix config.age.secretsDir secret.path)
                (lib.attrValues config.age.secrets)));
          # Bash path args are also matched absolute, so gate write locations here,
          # not in bash rules. The cwd root counts as inside; only `rm * ~*` catches it.
          external_directory_write = let
            roots =
              # /nix/store so `rm result` doesn't ask; ~/worktrees/* so a whole <repo> does.
              ["/tmp" "~/.local/share/agents" "~/worktrees/*" "/nix/store"];
          in
            {"*" = "ask";}
            // lib.listToAttrs (lib.concatMap (root: [
                (lib.nameValuePair "${root}/*" "allow")
                # The typed spelling is matched too, so `/tmp/../home` would ride the allow.
                (lib.nameValuePair "${root}/*..*" "ask")
              ])
              roots);
          bash = {
            # Explicit, or the top-level "*" still applies but warns at startup.
            "*" = "allow";
            # Last match wins and Nix sorts keys: `*` sorts first, so narrower rules win.
            # A computed path gets no absolute spelling, so the write gate can't see it.
            "rm * $*" = "ask";
            "rm * .*" = "ask";
            # Never produced from a relative argument, so only a typed ~ hits it.
            "rm * ~*" = "ask";
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
          };
        };
      };
    };
  };
}
