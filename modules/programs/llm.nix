# Local models on the dev.llm host's GPU, fronted by llama-swap so only one is
# loaded and only while something is actually asking (5 min TTL) — the card is
# shared with niri, the browser, and anything else wanting it.
# The model/quant/context set per card lives in _llm-models.nix.
#
# Weights stay out of the Nix store: up to 12 GiB each, and fetchurl can't resume.
# Run `llm-fetch` once; the service stays inactive until the files exist.
{
  flake.modules.homeManager.llm = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.fireproof.dev.llm;
    models = (import ./_llm-models.nix).${toString cfg.vramGiB};
    modelDir = "${config.home.homeDirectory}/models";
    filePath = f: "${modelDir}/${f.file}";
    # Stock build so it substitutes from cache.nixos-cuda.org; any change here (capabilities, src pin) means a local CUDA compile.
    llama-cpp = pkgs.unstable.llama-cpp.override {cudaSupport = true;};

    # --parallel defaults to auto in b10612+ and multiplies the KV/recurrent-state
    # caches per slot — without pinning it to 1 the MTP config OOMs on load.
    #
    # Sampling and --reasoning-effort are Qwen3.8's; other entries override them
    # through args, since the last occurrence of a flag wins.
    #
    # --reasoning-effort: the template defaults to xhigh, which burns tokens on a
    # local model; a client-sent reasoning_effort still overrides this.
    #
    # ${PORT} is llama-swap's macro, not Nix's.
    serverCmd = m:
      lib.concatStringsSep "\n" ([
          "${llama-cpp}/bin/llama-server"
          "--model ${filePath m.weights}"
          "--host 127.0.0.1"
          "--port \${PORT}"
          "--flash-attn on"
          "--n-gpu-layers 99"
          "--jinja"
          "--parallel 1"
          "--temp 1.0"
          "--top-p 0.95"
          "--top-k 20"
          "--ctx-size ${toString m.ctx}"
          "--reasoning-effort medium"
        ]
        ++ m.args);

    swapConfig = (pkgs.formats.yaml {}).generate "llama-swap.yaml" {
      healthCheckTimeout = 300;
      logLevel = "info";
      # The default "proxy" keeps llama-server's output (CUDA errors, load OOMs) out of the journal.
      logToStdout = "both";
      startPort = 10001;
      models =
        lib.mapAttrs (_: m: {
          inherit (m) name;
          cmd = serverCmd m;
          ttl = 300;
        })
        models;
    };

    weights = lib.unique (map (m: m.weights) (lib.attrValues models));

    # Only a finished download takes the final name, so a rerun resumes the .part.
    llm-fetch = pkgs.writeShellApplication {
      name = "llm-fetch";
      runtimeInputs = [pkgs.curl pkgs.coreutils];
      text = ''
        mkdir -p ${modelDir}
        ${lib.concatMapStrings (w: ''
            if [ -e "${filePath w}" ]; then
              echo "already present: ${w.file}"
            else
              echo "fetching ${w.file} (resumable)..."
              curl -L -C - --retry 5 --fail -o "${filePath w}.part" "${w.url}"
              mv "${filePath w}.part" "${filePath w}"
            fi
          '')
          weights}
        echo "done; start with: systemctl --user start llama-swap"
      '';
    };
  in {
    config = lib.mkIf (cfg.enable && pkgs.stdenv.isLinux) {
      home.packages = [
        # Pulled in by the service anyway; also gives llama-bench for retuning.
        llama-cpp
        llm-fetch
      ];

      systemd.user.services.llama-swap = {
        Unit = {
          Description = "llama-swap — on-demand local LLM router";
          # Idle until the weights are actually on disk.
          ConditionPathExists = map filePath weights;
        };
        Service = {
          ExecStart = "${pkgs.unstable.llama-swap}/bin/llama-swap -config ${swapConfig} -listen 127.0.0.1:9292";
          Restart = "on-failure";
          RestartSec = 5;
          # Inherited by llama-server, whose CUDA-abort core is ~15G and holds the VRAM while it streams.
          LimitCORE = 0;
        };
        Install.WantedBy = ["default.target"];
      };
    };
  };
}
