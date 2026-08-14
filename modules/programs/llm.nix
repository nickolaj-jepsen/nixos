# Qwen3.8-27B served locally on desktop's RTX 5070 Ti, fronted by llama-swap so
# the weights only hold VRAM while something is actually asking (5 min TTL) —
# the card is shared with niri, the browser, and anything else wanting it.
#
# Two quants, because no single one covers both jobs on 16GB:
#   UD-Q3_K_XL (12.51 GiB) — the default. Measured PPL 2.996 vs IQ3_XXS's 3.050
#     over 213 chunks of this repo, i.e. 1.8% better for ~the same tok/s (48 vs
#     50 short-context, 35 at 32k depth). IQ4_XS is a further 2.2% but spills to
#     CPU and collapses to 4.6 tok/s, so 4-bit isn't worth having on this card.
#   UD-IQ3_XXS (11.09 GiB) — only for the 128k entry: 128k of KV needs 2 GiB even
#     at q4_0, which Q3_K_XL leaves no room for.
#
# Weights stay out of the Nix store: 12 GiB each, and fetchurl can't resume. Run
# `llm-fetch` once; the service stays inactive until the files exist.
{
  flake.modules.homeManager.llm = {
    config,
    lib,
    pkgs,
    ...
  }: let
    modelDir = "${config.home.homeDirectory}/models";
    quants = {
      default = "Qwen3.8-27B-UD-Q3_K_XL.gguf";
      long = "Qwen3.8-27B-UD-IQ3_XXS.gguf";
    };
    modelPath = q: "${modelDir}/${q}";

    # ${PORT} is llama-swap's macro, not Nix's.
    serverCmd = q: ''
      ${pkgs.llama-cpp-cuda}/bin/llama-server
      --model ${modelPath q}
      --host 127.0.0.1
      --port ''${PORT}
      --flash-attn on
      --n-gpu-layers 99
      --jinja
      --temp 1.0
      --top-p 0.95
      --top-k 20
    '';

    # Top-level reasoning_effort is dropped by llama.cpp (upstream PR #26941 is
    # still open), so depth is pinned here; the template defaults to xhigh, which
    # burns tokens on a local model. A client-sent kwarg still overrides this.
    effort = ''--chat-template-kwargs '{"reasoning_effort":"medium"}' '';

    swapConfig = (pkgs.formats.yaml {}).generate "llama-swap.yaml" {
      healthCheckTimeout = 300;
      logLevel = "info";
      startPort = 10001;
      models = {
        # q4_0 KV rather than q8_0: 32k at q8_0 needs ~14.1 GiB and OOM'd once at
        # 14.06 GiB free, so it loses the race against a busy browser.
        "qwen3.8-27b" = {
          name = "Qwen3.8 27B (local 32k)";
          cmd = ''
            ${serverCmd quants.default}
            --ctx-size 32768
            --cache-type-k q4_0
            --cache-type-v q4_0
            ${effort}
          '';
          ttl = 300;
        };
        # Lands within ~300 MiB of the card's ceiling — it OOMs if the desktop is
        # using much VRAM.
        "qwen3.8-27b-128k" = {
          name = "Qwen3.8 27B (local 128k)";
          cmd = ''
            ${serverCmd quants.long}
            --ctx-size 131072
            --cache-type-k q4_0
            --cache-type-v q4_0
            ${effort}
          '';
          ttl = 300;
        };
      };
    };

    llm-fetch = pkgs.writeShellApplication {
      name = "llm-fetch";
      runtimeInputs = [pkgs.curl pkgs.coreutils];
      text = ''
        mkdir -p ${modelDir}
        for q in ${lib.concatStringsSep " " (lib.attrValues quants)}; do
          if [ -s "${modelDir}/$q" ]; then
            echo "already present: $q"
            continue
          fi
          echo "fetching $q (~12 GiB, resumable)..."
          curl -L -C - --retry 5 --fail -o "${modelDir}/$q" \
            "https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/$q"
        done
        echo "done; start with: systemctl --user start llama-swap"
      '';
    };
  in {
    config = lib.mkIf (config.fireproof.dev.llm.enable && pkgs.stdenv.isLinux) {
      home.packages = [
        # Pulled in by the service anyway; also gives llama-bench for retuning.
        pkgs.llama-cpp-cuda
        llm-fetch
      ];

      systemd.user.services.llama-swap = {
        Unit = {
          Description = "llama-swap — on-demand local LLM router";
          # Idle until the weights are actually on disk.
          ConditionPathExists = modelPath quants.default;
          After = ["network.target"];
        };
        Service = {
          ExecStart = "${pkgs.unstable.llama-swap}/bin/llama-swap -config ${swapConfig} -listen 127.0.0.1:9292";
          Restart = "on-failure";
          RestartSec = 5;
        };
        Install.WantedBy = ["default.target"];
      };
    };
  };
}
