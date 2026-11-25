# llama-swap entries per VRAM tier (fireproof.dev.llm.vramGiB), shared by the
# server and the agents that use it as a provider. Every tier reuses the id
# "qwen3.8-27b" for its default entry so clients don't care which host they hit.
#
# q4_0 KV on the 27B: 32k at q8_0 needs ~14.1 GiB on the 16 GiB tier and OOM'd
# once at 14.06 GiB free, so it loses the race against a busy browser.
let
  byteshape = file: {
    inherit file;
    url = "https://huggingface.co/byteshape/Qwen3.8-27B-GGUF/resolve/main/${file}";
  };
  unsloth = repo: path: {
    file = baseNameOf path;
    url = "https://huggingface.co/unsloth/${repo}/resolve/main/${path}";
  };
  kvQ4 = ["--cache-type-k q4_0" "--cache-type-v q4_0"];
  # 8.2 GiB at 128k on either card; 256k fits only with q4_0 KV, at ~40 tok/s.
  # Thinking only when the client asks; Qwen's non-thinking sampling.
  qwen35-4b = {
    name = "Qwen3.5 4B";
    weights = unsloth "Qwen3.5-4B-MTP-GGUF" "Qwen3.5-4B-UD-Q4_K_XL.gguf";
    ctx = 131072;
    args = [
      "--spec-type draft-mtp"
      "--spec-draft-n-max 2"
      "--reasoning off"
      "--temp 0.7"
      "--top-p 0.8"
    ];
  };
  # The GGUFs carry the model's own MTP head (blk.*.nextn.*), so drafting with
  # it is lossless. Draft cache q4_0 for the same reason as the main cache.
  mtp = [
    "--spec-type draft-mtp"
    "--spec-draft-n-max 3"
    "--spec-draft-type-k q4_0"
    "--spec-draft-type-v q4_0"
  ];
  # Ternary QAT of Qwen3.8 27B, same template and sampling. Q2_0 is the only
  # packing stock llama.cpp loads (PTQ1_0/PQ2_0 need the PrismML fork), and
  # builds before b11556 load it silently and emit garbage. The -mtp file
  # carries PrismML's draft head; draft flags are their CUDA preset's.
  bonsai25 = {
    name = "Bonsai 2.5 27B";
    weights = {
      file = "Ternary-Bonsai-2.5-27B-Q2_0-mtp.gguf";
      url = "https://huggingface.co/prism-ml/Ternary-Bonsai-2.5-27B-GGUF/resolve/main/Ternary-Bonsai-2.5-27B-Q2_0-mtp.gguf";
    };
    # On the 4070: 8.8 GiB at 32k, ~28 MiB per 1k beyond, ~98 tok/s vs IQ2_XXS's
    # ~69. 48k stays under the IQ2_XXS entry's 9.4 GiB; 64k (9.7 GiB) doesn't.
    ctx = 49152;
    args =
      kvQ4
      ++ mtp
      ++ [
        "--spec-draft-n-min 0"
        "--spec-draft-p-min 0.1"
        "--ubatch-size 256"
      ];
  };
in {
  # desktop, RTX 5070 Ti. The desktop holds 1.1–1.6 GiB, and the model is capped
  # at ~13.7 GiB so the compositor keeps ~1 GiB of headroom: a failed display
  # allocation wedges nvidia-drm page flips until reboot. KV costs ~27 MiB per
  # 1k ctx with MTP and ubatch 256; IQ4_XS above 48k or IQ3_S above 112k loads
  # only with the desktop under ~1.2 GiB.
  "16" = {
    "qwen3.8-27b" = {
      name = "Qwen3.8 27B";
      weights = byteshape "Qwen3.8-27B-IQ3_S-3.23bpw.gguf";
      ctx = 98304;
      args = kvQ4 ++ mtp ++ ["--ubatch-size 256"];
    };

    # Fast entry: models past ~300 tok/s failed a quarter of bash-tool tasks.
    "qwen3.5-4b" = qwen35-4b;
  };

  # work, RTX 4070. The desktop holds 1.8–2.1 GiB (all three monitors hang off
  # this card), and loads start failing around 11.7 GiB total, so the model
  # gets ~9.6 GiB: room for one of MTP, 64k or IQ3 over plain IQ2 32k, never
  # two. KV is ~23 MiB per 1k tokens.
  # llm.nix pins --n-gpu-layers 99 rather than letting --fit offload: CPU layers drop
  # it to 12–15 tok/s, so a failed load is the better signal that the desktop
  # is using too much VRAM.
  "12" = {
    # Fails to load once the desktop holds more than ~2.4 GiB; without MTP it
    # would tolerate ~3.2.
    "qwen3.8-27b" = {
      name = "Qwen3.8 27B";
      weights = byteshape "Qwen3.8-27B-IQ2_XXS-2.56bpw.gguf";
      ctx = 32768;
      # The MTP draft's compute buffer is sized by ubatch; 256 instead of the
      # default 512 saves ~240 MiB with prefill speed unchanged.
      args = kvQ4 ++ mtp ++ ["--ubatch-size 256"];
    };
    "bonsai-2.5-27b" = bonsai25;
    "qwen3.5-4b" = qwen35-4b;
  };
}
