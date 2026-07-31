# Pi coding agent via pi.nix; the package roster is based on the lazypi
# catalog (https://lazypi.org).
#
# The packages array is authoritative: pi.nix jq-merges settings into
# ~/.pi/agent/settings.json on every launch and arrays replace wholesale —
# imperative `pi install`/`pi remove` edits revert at next start, and entries
# removed here stop loading but leave their download in ~/.pi/agent/{npm,git}.
{
  flake.modules.homeManager.pi = {
    config,
    lib,
    pkgs,
    inputs,
    ...
  }: {
    imports = [inputs.pi.homeModules.default];

    config = lib.mkIf config.fireproof.dev.pi.enable {
      programs.pi.coding-agent = {
        enable = true;
        # Shared with claude-code and copilot (agents.nix); keep it agent-agnostic.
        rules = builtins.readFile ./agent-context.md;
        # The fireproof.agents.skills registry, linked into one dir.
        skills = [(pkgs.linkFarm "pi-skills" config.fireproof.agents.skills)];
        # Nix-built pi can't self-update; extension-update notices still show.
        environment.PI_SKIP_VERSION_CHECK.value = "1";
        # pi-lens prepends its findings to the message list, so every turn it has
        # something to say invalidates the whole cached prefix. Its tools, LSP,
        # read-guard and formatting are unaffected; findings stay reachable via
        # lens_diagnostics and /lens-health.
        environment.PI_LENS_NO_CONTEXT_INJECTION.value = "1";
        settings.packages = [
          # extension-settings must load before powerbar (its settings panel).
          "npm:@juanibiapina/pi-extension-settings"
          # core
          "npm:pi-subagents"
          "npm:@juicesharp/rpiv-ask-user-question"
          "npm:pi-mcp-adapter"
          "npm:pi-web-access"
          # Plan mode + code review in one; replaced pi-plan and pi-simplify.
          "npm:@plannotator/pi-extension"
          # Claude Code CLI login as model provider — no API key in the flake.
          "npm:pi-claude-cli"
          # guardrails
          "npm:@gotgenes/pi-permission-system"
          # feedback + context diet
          "npm:pi-lens"
          "npm:@hypabolic/pi-hypa"
          # Keeps the prompt prefix stable so the tensorx proxy can actually
          # cache it; `/cache-optimizer doctor` reports the hit rate.
          "npm:pi-cache-optimizer"
          # ui
          "npm:@juanibiapina/pi-powerbar"
          "npm:@tmustier/pi-usage-extension"
          "npm:@juicesharp/rpiv-todo"
          "npm:@ayulab/pi-rewind"
        ];
      };

      age.secrets.tensorx-api-key = {
        rekeyFile = ../../secrets/tensorx-api-key.age;
        mode = "0600";
      };

      # Not the module's `models` option: that one only installs models.json when
      # the file is absent, so later edits here would never reach an existing
      # install.
      #
      # Per-model metadata mirrors each vendor's own entry in pi's built-in
      # catalog, minus the flags that assume the vendor's native wire format
      # survives a proxy (kimi's deferredToolsMode, glm's zai thinkingFormat +
      # zaiToolStream) — pi drops those for the gateway-hosted copies too.
      home.file.".pi/agent/models.json".text = builtins.toJSON {
        providers.tensorx = {
          baseUrl = "https://api.tensorx.ai/v1";
          api = "openai-completions";
          # `!cmd` runs via `sh -c`, which is what expands the shell syntax agenix
          # bakes into `.path` ($XDG_RUNTIME_DIR on linux, $(getconf …) on darwin).
          # Keeps the key on tmpfs and out of the world-readable store.
          apiKey = "!cat ${config.age.secrets.tensorx-api-key.path}";
          # pi auto-detects compat from provider name/baseUrl and falls back to
          # OpenAI's own dialect for anything it doesn't recognise, which none of
          # these upstreams speak. Pin the lowest common denominator instead.
          compat = {
            supportsStore = false;
            supportsDeveloperRole = false;
            supportsReasoningEffort = true;
            maxTokensField = "max_tokens";
            supportsStrictMode = false;
            thinkingFormat = "openai";
            # Sticky-routing hint for pi-cache-optimizer: a gateway that spreads
            # one session over several upstreams can't hit its own prompt cache.
            # Just extra headers — ignored if tensorx doesn't honour them.
            sendSessionAffinityHeaders = true;
          };
          models = [
            {
              id = "moonshotai/kimi-k3";
              name = "Kimi K3 (TensorX)";
              reasoning = true;
              input = ["text" "image"];
              contextWindow = 1048576;
              maxTokens = 131072;
              # Costs across all three are TensorX's own published rates; their
              # cache hits are documented as best-effort, not guaranteed.
              cost = {
                input = 3;
                output = 15;
                cacheRead = 0.75;
                cacheWrite = 0;
              };
              # K3 always reasons; only low/high/max are real effort levels.
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
            {
              id = "z-ai/glm-5.2";
              name = "GLM 5.2 (TensorX)";
              reasoning = true;
              input = ["text"];
              # TensorX caps this one at 198K, well short of Z.ai's own 1M.
              contextWindow = 198000;
              maxTokens = 128000;
              cost = {
                input = 1.5;
                output = 4.5;
                cacheRead = 0.38;
                cacheWrite = 0;
              };
            }
            {
              id = "minimax/minimax-m3";
              name = "MiniMax M3 (TensorX)";
              reasoning = true;
              input = ["text" "image"];
              # TensorX publishes no context window for M3; these are MiniMax's.
              contextWindow = 1000000;
              maxTokens = 128000;
              cost = {
                input = 0.4;
                output = 2;
                cacheRead = 0.1;
                cacheWrite = 0;
              };
            }
            {
              id = "deepseek/deepseek-v4-flash";
              name = "DeepSeek V4 Flash (TensorX)";
              reasoning = true;
              input = ["text"];
              contextWindow = 1000000;
              # TensorX publishes no output cap; DeepSeek's own figure.
              maxTokens = 384000;
              cost = {
                input = 0.15;
                output = 0.3;
                cacheRead = 0.04;
                cacheWrite = 0;
              };
              # Only high/max are real effort levels upstream.
              thinkingLevelMap = {
                off = null;
                minimal = null;
                low = null;
                medium = null;
                high = "high";
                xhigh = null;
                max = "max";
              };
            }
          ];
        };
      };

      # Nix-owned (read-only), so pi's "persist globally" approval won't stick;
      # session approvals still work.
      home.file.".pi/agent/extensions/pi-permission-system/config.json".text = builtins.toJSON {
        permission = {
          "*" = "allow";
          path = {
            "*.env" = "deny";
            "*.env.*" = "deny";
            "*.env.example" = "allow";
          };
          bash = {
            "rm -rf /" = "deny";
            "sudo rm *" = "deny";
            "rm -rf *" = "ask";
            "sudo *" = "ask";
            "git push --force*" = "ask";
          };
        };
      };
    };
  };
}
