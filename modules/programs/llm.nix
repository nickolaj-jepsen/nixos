# Qwen3.8-27B served locally on desktop's RTX 5070 Ti, fronted by llama-swap so
# the weights only hold VRAM while something is actually asking (5 min TTL) —
# the card is shared with niri, the browser, and anything else wanting it.
#
# Two quants, because no single one covers both jobs on 16GB:
#   UD-Q3_K_XL (~12.5 GiB) — the default. Measured PPL 2.996 vs IQ3_XXS's 3.050
#     over 213 chunks of this repo, i.e. 1.8% better for ~the same tok/s (48 vs
#     50 short-context, 35 at 32k depth). IQ4_XS is a further 2.2% but spills to
#     CPU and collapses to 4.6 tok/s, so 4-bit isn't worth having on this card.
#   UD-IQ3_XXS (~11 GiB) — only for the 128k entry: 128k of KV needs 2 GiB even
#     at q4_0, which Q3_K_XL leaves no room for.
#
# Unsloth replaced both files in-place with Dynamic v3 on 2026-08-19 (~10%
# better accuracy at the same size, same URLs) — the PPL figures above are from
# the launch-day files, but the size/speed tradeoff stands. To pick v3 up:
# rm ~/models/*.gguf && llm-fetch.
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
      --parallel 1
      --temp 1.0
      --top-p 0.95
      --top-k 20
    '';

    # --parallel defaults to auto in b10612+ and multiplies the KV/recurrent-state
    # caches per slot — without pinning it to 1 the MTP config OOMs on load.
    #
    # The template defaults to xhigh, which burns tokens on a local model. Needs
    # the b10612 overlay pin (PR #26941 merged after nixpkgs' b10408); a
    # client-sent reasoning_effort still overrides this.
    effort = "--reasoning-effort medium";

    swapConfig = (pkgs.formats.yaml {}).generate "llama-swap.yaml" {
      healthCheckTimeout = 300;
      logLevel = "info";
      startPort = 10001;
      models = {
        # q4_0 KV rather than q8_0: 32k at q8_0 needs ~14.1 GiB and OOM'd once at
        # 14.06 GiB free, so it loses the race against a busy browser.
        "qwen3.8-27b" = {
          name = "Qwen3.8 27B (local 32k)";
          # The GGUF carries the model's own MTP head (blk.*.nextn.*), so drafting
          # with it is lossless. Measured 2026-08-24 on the v3 quant: 47 tok/s
          # bare, 81 at n-max 2, 89 at n-max 3 (n-max 3 costs only ~200 MiB
          # more; total ~15.5 GiB with the desktop holding 1.4). Draft cache
          # q4_0 for the same reason as the main cache.
          cmd = ''
            ${serverCmd quants.default}
            --ctx-size 32768
            --cache-type-k q4_0
            --cache-type-v q4_0
            --spec-type draft-mtp
            --spec-draft-n-max 3
            --spec-draft-type-k q4_0
            --spec-draft-type-v q4_0
            ${effort}
          '';
          ttl = 300;
        };
        # ~1.2 GiB of headroom since the smaller v3 quant, but still no MTP:
        # the draft context wants another ~720 MiB that isn't there (measured
        # 2026-08-24), and it OOMs if the desktop is using much VRAM.
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
