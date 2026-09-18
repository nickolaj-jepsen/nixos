# llama-swap entries per VRAM tier (fireproof.dev.llm.vramGiB), shared by
# llm.nix (serving) and pi.nix (provider). Every tier reuses the id
# "qwen3.8-27b" for its default entry so clients don't care which host they hit.
#
# q4_0 KV everywhere: 32k at q8_0 needs ~14.1 GiB on the 16 GiB tier and OOM'd
# once at 14.06 GiB free, so it loses the race against a busy browser.
let
  unsloth = file: {
    inherit file;
    url = "https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/${file}";
  };
  byteshape = file: {
    inherit file;
    url = "https://huggingface.co/byteshape/Qwen3.8-27B-GGUF/resolve/main/${file}";
  };
  kvQ4 = ["--cache-type-k q4_0" "--cache-type-v q4_0"];
  # The GGUFs carry the model's own MTP head (blk.*.nextn.*), so drafting with
  # it is lossless. Draft cache q4_0 for the same reason as the main cache.
  mtp = [
    "--spec-type draft-mtp"
    "--spec-draft-n-max 3"
    "--spec-draft-type-k q4_0"
    "--spec-draft-type-v q4_0"
  ];
in {
  # desktop, RTX 5070 Ti. Two quants, because no single one covers both jobs:
  #   UD-Q3_K_XL (~12.5 GiB) — the default. Measured PPL 2.996 vs IQ3_XXS's
  #     3.050 over 213 chunks of this repo, i.e. 1.8% better for ~the same tok/s
  #     (48 vs 50 short-context, 35 at 32k depth). IQ4_XS is a further 2.2% but
  #     spills to CPU and collapses to 4.6 tok/s, so 4-bit isn't worth having.
  #   UD-IQ3_XXS (~11 GiB) — only for the 128k entry: 128k of KV needs 2 GiB
  #     even at q4_0, which Q3_K_XL leaves no room for.
  #
  # Unsloth replaced both files in-place with Dynamic v3 on 2026-08-19 (~10%
  # better accuracy at the same size, same URLs) — the PPL figures above are
  # from the launch-day files, but the size/speed tradeoff stands. To pick v3
  # up: rm ~/models/*.gguf && llm-fetch.
  "16" = {
    "qwen3.8-27b" = {
      name = "Qwen3.8 27B (local 32k)";
      weights = unsloth "Qwen3.8-27B-UD-Q3_K_XL.gguf";
      ctx = 32768;
      # Measured 2026-08-24 on the v3 quant: 47 tok/s bare, 81 at n-max 2, 89
      # at n-max 3 (n-max 3 costs only ~200 MiB more; total ~15.5 GiB with the
      # desktop holding 1.4).
      args = kvQ4 ++ mtp;
    };
    # ~1.2 GiB of headroom since the smaller v3 quant, but still no MTP: the
    # draft context wants another ~720 MiB that isn't there (measured
    # 2026-08-24), and it OOMs if the desktop is using much VRAM.
    "qwen3.8-27b-128k" = {
      name = "Qwen3.8 27B (local 128k)";
      weights = unsloth "Qwen3.8-27B-UD-IQ3_XXS.gguf";
      ctx = 131072;
      args = kvQ4;
    };
  };

  # work, RTX 4070. Only ByteShape's 2.56 bpw IQ2_XXS (8.2 GiB, 93% of BF16 on
  # their benchmark mix) fits; their 3.23 bpw IQ3_S is 10.3 GiB and doesn't
  # leave room beside the desktop, which holds 1.5–2.6 GiB and drifts upward.
  #
  # Peak own VRAM, measured 2026-09-18 on b11018 (~1.1k tok/s prefill for all):
  #   32k, no MTP: 8.5 GiB, 42 tok/s
  #   16k + MTP:   8.9 GiB, 64 tok/s
  #   24k + MTP:   OOM'd on load with the desktop at 2.5 GiB
  # Letting --fit offload layers instead of pinning -ngl 99 always loads, but
  # a few CPU layers drop it to 12–15 tok/s, so a failed load is the better
  # signal to fall back to the default entry.
  "12" = {
    "qwen3.8-27b" = {
      name = "Qwen3.8 27B IQ2 (local 32k)";
      weights = byteshape "Qwen3.8-27B-IQ2_XXS-2.56bpw.gguf";
      ctx = 32768;
      args = kvQ4;
    };
    # Fails to load once the desktop holds more than ~2.8 GiB.
    "qwen3.8-27b-fast" = {
      name = "Qwen3.8 27B IQ2 (local 16k, MTP)";
      weights = byteshape "Qwen3.8-27B-IQ2_XXS-2.56bpw.gguf";
      ctx = 16384;
      # The MTP draft's compute buffer is sized by ubatch; 256 instead of the
      # default 512 saves ~240 MiB with prefill speed unchanged.
      args = kvQ4 ++ mtp ++ ["--ubatch-size 256"];
    };
  };
}
