# opencode 2.x, built from the upstream flake (nixpkgs is still on 1.x).
#
# The HM module only installs the package and AGENTS.md: it targets v1 (v1
# $schema, v1-shaped `mcp`), so opencode.json is written here in v2 shape.
# Skills aren't linked either — v2 already discovers ~/.claude/skills, which
# claude-code fills from the same fireproof.agents.skills registry. v2 starts
# no language servers, so fireproof.agents.lspServers doesn't apply.
{inputs, ...}: {
  flake.modules.homeManager.opencode = {
    config,
    lib,
    pkgs,
    ...
  }: let
    llm = config.fireproof.dev.llm;

    noCost = {
      input = 0;
      output = 0;
    };

    # Served by llama-swap (modules/programs/llm.nix), which holds one entry at
    # a time — switching between them costs a ~15s reload.
    local = {
      name = "Local (llama-swap)";
      package = "@opencode/ai/providers/openai-compatible";
      settings.baseURL = "http://127.0.0.1:9292/v1";
      compatibility.maxTokensField = "max_tokens";
      models =
        lib.mapAttrs (_: m: let
          thinks = !(lib.elem "--reasoning off" m.args);
        in {
          inherit (m) name;
          # mmproj isn't loaded — no VRAM left for the vision tower.
          capabilities = {
            tools = true;
            input = ["text"];
            output = ["text"];
          };
          limit = {
            context = m.ctx;
            output = 8192;
          };
          cost = noCost;
          # llama.cpp drops reasoning_effort (the depth is pinned per llama-swap
          # entry), so the only switch is flipping the entry's thinking default.
          variants = [
            {
              id =
                if thinks
                then "fast"
                else "think";
              body.chat_template_kwargs.enable_thinking = !thinks;
            }
          ];
        })
        (import ./_llm-models.nix).${toString llm.vramGiB};
    };

    efforts = map (id: {
      inherit id;
      settings.reasoningEffort = id;
    });

    # Hand-picked overrides; opencode's bundled catalog lists the rest of TensorX.
    tensorx = {
      name = "TensorX";
      package = "@opencode/ai/providers/openai-compatible";
      settings = {
        baseURL = "https://api.tensorx.ai/v1";
        apiKey = "{file:${config.age.secrets.tensorx-api-key.path}}";
      };
      compatibility.maxTokensField = "max_tokens";
      models = {
        "moonshotai/kimi-k3" = {
          name = "Kimi K3 (TensorX)";
          capabilities.input = ["text" "image"];
          limit = {
            context = 1048576;
            output = 131072;
          };
          cost = {
            input = 3;
            output = 15;
            cache.read = 0.75;
          };
          # K3 always reasons; only low/high/max are real levels.
          variants = efforts ["low" "high" "max"];
        };
        "z-ai/glm-5.3-flash" = {
          name = "GLM 5.3 Flash (TensorX)";
          capabilities.input = ["text" "image"];
          limit = {
            context = 1000000;
            output = 131072;
          };
          cost = {
            input = 0.2;
            output = 0.5;
            cache.read = 0.05;
          };
          variants = efforts ["low" "high" "max"];
        };
        "z-ai/glm-5.2" = {
          name = "GLM 5.2 (TensorX)";
          capabilities.input = ["text"];
          # TensorX caps this one at 198K, well short of Z.ai's own 1M.
          limit = {
            context = 198000;
            output = 128000;
          };
          cost = {
            input = 1.5;
            output = 4.5;
            cache.read = 0.38;
          };
        };
        "minimax/minimax-m3" = {
          name = "MiniMax M3 (TensorX)";
          capabilities.input = ["text" "image"];
          limit = {
            context = 1000000;
            output = 128000;
          };
          cost = {
            input = 0.4;
            output = 2;
            cache.read = 0.1;
          };
        };
        "deepseek/deepseek-v4.1-flash" = {
          name = "DeepSeek V4.1 Flash (TensorX)";
          capabilities.input = ["text" "image"];
          limit = {
            context = 1048576;
            output = 64000;
          };
          cost = {
            input = 0.5;
            output = 1.5;
            cache.read = 0.13;
          };
          # DeepSeek rejects replayed turns missing reasoning_content.
          compatibility = {
            reasoningField = "reasoning_content";
            requireReasoning = true;
          };
          variants = efforts ["high" "max"];
        };
        # TensorX only serves the dated snapshot, not the bare alias.
        "deepseek/deepseek-v4-flash-0731" = {
          name = "DeepSeek V4 Flash 0731 (TensorX)";
          capabilities.input = ["text"];
          limit = {
            context = 1000000;
            output = 384000;
          };
          cost = {
            input = 0.25;
            output = 0.3;
            cache.read = 0.06;
          };
          # DeepSeek rejects replayed turns missing reasoning_content.
          compatibility = {
            reasoningField = "reasoning_content";
            requireReasoning = true;
          };
          variants = efforts ["high" "max"];
        };
        "qwen/qwen3.8-flash-next" = {
          name = "Qwen3.8 Flash Next (TensorX)";
          capabilities.input = ["text" "image"];
          # Native window — the 1M YaRN stretch isn't what TensorX serves.
          limit = {
            context = 262144;
            output = 131072;
          };
          cost = {
            input = 0.2;
            output = 0.5;
            cache.read = 0.05;
          };
          variants = efforts ["low" "medium" "xhigh"];
        };
      };
    };

    # Same catalog pi reads (./_synthetic-models.nix), mapped to opencode's schema.
    synthetic = {
      name = "Synthetic";
      package = "@opencode/ai/providers/openai-compatible";
      settings = {
        baseURL = "https://api.synthetic.new/openai/v1";
        apiKey = "{file:${config.age.secrets.synthetic-api-key.path}}";
      };
      compatibility.maxTokensField = "max_tokens";
      models =
        lib.mapAttrs (_id: m: {
          inherit (m) name;
          capabilities = {
            tools = true;
            inherit (m) input;
            output = ["text"];
          };
          limit = {
            context = m.ctx;
            output = m.maxOut;
          };
          cost = {
            input = m.cost.input;
            output = m.cost.output;
            cache.read = m.cost.cached;
          };
          # The endpoint's own efforts, one variant each.
          variants =
            map (effort: {
              id = effort;
              settings.reasoningEffort = effort;
            })
            m.efforts;
        })
        (import ./_synthetic-models.nix);
    };

    mcpServer = s: let
      enabled =
        if (s.enabled or null) != null
        then s.enabled
        else !(s.disabled or false);
    in
      lib.optionalAttrs enabled (
        if (s.url or null) != null
        then
          {
            type = "remote";
            inherit (s) url;
          }
          // lib.optionalAttrs (s.headers != {}) {inherit (s) headers;}
        else
          {
            type = "local";
            command = [s.command] ++ (s.args or []);
          }
          // lib.optionalAttrs (s.env != {}) {
            environment = lib.hm.mcp.renderEnv (path: "{file:${path}}") s.env;
          }
      );
  in {
    config = lib.mkIf config.fireproof.dev.opencode.enable {
      programs.opencode = {
        enable = true;
        package = inputs.opencode.packages.${pkgs.stdenv.hostPlatform.system}.opencode;
        # Shared by every agent; keep it agent-agnostic.
        context = builtins.readFile ./agent-context.md;
      };

      xdg.configFile."opencode/opencode.json".text = builtins.toJSON ({
          "$schema" = "https://opencode.ai/config.json";
          # Nix owns the binary.
          update = "disable";
          # Refuses `git worktree add` outside ~/worktrees/<repo>/; the layout and
          # the check live in `wt guard` (modules/scripts/wt.py), shared with the
          # Claude Code and pi adapters. A store path, so no plugin install step.
          plugins = ["file://${./opencode/worktree-guard.js}"];
          # Not Kimi K3.1 Pro: on Go's metered rate it would eat the monthly
          # allowance in minutes, and only pi's router can fall back when it does.
          model =
            if llm.enable
            then "local/qwen3.8-27b"
            else "tensorx/deepseek/deepseek-v4.1-flash";
          # Remote, so titling a session never evicts the local model from llama-swap.
          agents.title.model = "tensorx/z-ai/glm-5.3-flash";
          providers =
            lib.optionalAttrs llm.enable {inherit local;}
            // {
              inherit tensorx;
              inherit synthetic;
              # The built-in catalog supplies the models; only the key is ours.
              opencode-go.settings.apiKey = "{file:${config.age.secrets.opencode-go-api-key.path}}";
            };
        }
        // lib.optionalAttrs (config.programs.mcp.enable && config.programs.mcp.servers != {}) {
          mcp.servers = lib.filterAttrs (_: v: v != {}) (lib.mapAttrs (_: mcpServer) config.programs.mcp.servers);
        });
    };
  };
}
