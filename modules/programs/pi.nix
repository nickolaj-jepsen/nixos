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
        # Read at launch, so the key never lands in the Nix store.
        environment.KAGI_API_KEY.file = config.age.secrets.kagi-api-key.path;
        settings.packages = [
          # extension-settings must load before powerbar (its settings panel).
          "npm:@juanibiapina/pi-extension-settings"
          # core
          "npm:@juicesharp/rpiv-ask-user-question"
          "npm:pi-mcp-adapter"
          "npm:@plannotator/pi-extension"
          # Kagi search/extract; far cheaper in context than pi-web-access.
          "npm:@mjakl/pi-kagi-api"
          # Claude Code CLI login as model provider — no API key in the flake.
          "npm:pi-claude-cli"
          # guardrails
          "npm:@gotgenes/pi-permission-system"
          # context diet
          "npm:pi-cache-optimizer"
          # ui
          "npm:@juanibiapina/pi-powerbar"
          "npm:@tmustier/pi-usage-extension"
          "npm:@juicesharp/rpiv-todo"
          "npm:@ayulab/pi-rewind"
        ];
      };

      # Explicit path: the wrapper single-quotes this, so the default
      # ${XDG_RUNTIME_DIR} spelling would reach `cat` unexpanded. uid 1000 = the
      # primary user, same tmpfs dir agenix would have picked itself.
      age.secrets.kagi-api-key = {
        rekeyFile = ../../secrets/kagi-api-key.age;
        path = "/run/user/1000/agenix/kagi-api-key";
        mode = "0600";
      };

      age.secrets.tensorx-api-key = {
        rekeyFile = ../../secrets/tensorx-api-key.age;
        mode = "0600";
      };

      # Not the module's `models` option — it only writes once, never updates.
      home.file.".pi/agent/models.json".text = builtins.toJSON {
        providers =
          lib.optionalAttrs config.fireproof.dev.llm.enable {
            # Served by llama-swap (modules/programs/llm.nix), which unloads one
            # entry to load the other — switching costs a ~15s reload. The 128k
            # entry runs a smaller quant; only it leaves room for 128k of KV.
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
              models = [
                {
                  id = "qwen3.8-27b";
                  name = "Qwen3.8 27B (local 32k)";
                  reasoning = true;
                  # mmproj isn't loaded — no VRAM left for the vision tower.
                  input = ["text"];
                  contextWindow = 32768;
                  maxTokens = 8192;
                  cost = {
                    input = 0;
                    output = 0;
                    cacheRead = 0;
                    cacheWrite = 0;
                  };
                }
                {
                  id = "qwen3.8-27b-128k";
                  name = "Qwen3.8 27B (local 128k)";
                  reasoning = true;
                  input = ["text"];
                  contextWindow = 131072;
                  maxTokens = 8192;
                  cost = {
                    input = 0;
                    output = 0;
                    cacheRead = 0;
                    cacheWrite = 0;
                  };
                }
              ];
            };
          }
          // {
            tensorx = {
              baseUrl = "https://api.tensorx.ai/v1";
              api = "openai-completions";
              # `!cmd` keeps the key on tmpfs, out of the Nix store.
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
              models = [
                {
                  id = "moonshotai/kimi-k3";
                  name = "Kimi K3 (TensorX)";
                  reasoning = true;
                  input = ["text" "image"];
                  contextWindow = 1048576;
                  maxTokens = 131072;
                  cost = {
                    input = 3;
                    output = 15;
                    cacheRead = 0.75;
                    cacheWrite = 0;
                  };
                  # K3 always reasons; only low/high/max are real levels.
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
                  # TensorX only serves the dated snapshot, not the bare alias.
                  id = "deepseek/deepseek-v4-flash-0731";
                  name = "DeepSeek V4 Flash 0731 (TensorX)";
                  reasoning = true;
                  input = ["text"];
                  contextWindow = 1000000;
                  # TensorX publishes no output cap; DeepSeek's own figure.
                  maxTokens = 384000;
                  cost = {
                    input = 0.25;
                    output = 0.3;
                    cacheRead = 0.06;
                    cacheWrite = 0;
                  };
                  compat = {
                    # DeepSeek rejects replayed turns missing reasoning_content.
                    requiresReasoningContentOnAssistantMessages = true;
                    thinkingFormat = "deepseek";
                    supportsLongCacheRetention = true;
                  };
                  # `off` stays unset, not null, or it's dropped from the picker.
                  thinkingLevelMap = {
                    minimal = null;
                    low = null;
                    medium = null;
                    high = "high";
                    max = "max";
                  };
                }
              ];
            };
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
