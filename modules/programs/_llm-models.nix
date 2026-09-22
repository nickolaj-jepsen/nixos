# llama-swap entries per VRAM tier (fireproof.dev.llm.vramGiB), shared by
# llm.nix (serving) and pi.nix (provider). Every tier reuses the id
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
  # 5.8 GiB at 64k on either card. Thinking only when the client asks; Qwen's
  # non-thinking sampling.
  qwen35-4b = {
    name = "Qwen3.5 4B (local fast 64k)";
    weights = unsloth "Qwen3.5-4B-MTP-GGUF" "Qwen3.5-4B-UD-Q4_K_XL.gguf";
    ctx = 65536;
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
in {
  # desktop, RTX 5070 Ti. The desktop holds 1.1–1.6 GiB, and the model is capped
  # at ~13.7 GiB so the compositor keeps ~1 GiB of headroom: a failed display
  # allocation wedges nvidia-drm page flips until reboot. Two quants, because
  # context and bits compete for it.
  #
  # Measured 2026-09-18 on b11018. Score vs BF16 on ByteShape's benchmark mix /
  # PPL over this repo / HumanEval+ (±3 tasks of noise):
  #   byteshape IQ4_XS 3.84 bpw, 12.2 GiB: 99.6% / 3.541 / 89.6%
  #   unsloth UD-Q3_K_XL,        12.2 GiB: 97.6% / 3.516 / 87.8%
  #   byteshape IQ3_S 3.23 bpw,  10.3 GiB: 98.7% / 3.688 / 90.9%
  #   unsloth UD-IQ3_XXS,        10.2 GiB: 93.6% / 3.615 / 90.2%
  # Only the vendor score separates them; ByteShape also takes ~150 MiB less.
  # q4_0 KV costs nothing measurable: PPL at 8k is 2.739 f16, 2.710 q4_0.
  #
  # Own VRAM, tok/s short, tok/s at depth; MTP + ubatch 256, ~27 MiB per 1k ctx:
  #   IQ4_XS 32k:  13.7 GiB, 97
  #   IQ4_XS 48k:  14.1 GiB, 97, 69 at 42k
  #   IQ3_S 96k:   13.5 GiB, 96, 61 at 83k
  #   IQ3_S 112k:  14.0 GiB, 94, 51 at 104k
  #   IQ4_XS 64k, IQ3_S 128k: load only with the desktop under ~1.2 GiB
  #   128k without MTP: 13.4 GiB, 55, 23 at 83k
  # ngram-mod on top of MTP gains nothing; DFlash2 drafting needs 1.1 GiB more.
  "16" = {
    "qwen3.8-27b" = {
      name = "Qwen3.8 27B (local 32k)";
      weights = byteshape "Qwen3.8-27B-IQ4_XS-3.84bpw.gguf";
      ctx = 32768;
      args = kvQ4 ++ mtp ++ ["--ubatch-size 256"];
    };
    "qwen3.8-27b-long" = {
      name = "Qwen3.8 27B (local 96k)";
      weights = byteshape "Qwen3.8-27B-IQ3_S-3.23bpw.gguf";
      ctx = 98304;
      args = kvQ4 ++ mtp ++ ["--ubatch-size 256"];
    };

    # Fast entries, measured 2026-09-18 with thinking off: tok/s raw / tok/s on
    # tool-call turns / of 60 bash-tool tasks passed / s per 20 / HumanEval+.
    # The 27B: 100 / 97 / 60 / 56 / 89.6%.
    #   Qwen3.5-4B + MTP:             255 / 247 / 59 / 24 / 80.5%
    #   Gemma 4 26B-A4B Q3 + MTP:     235 / 181 / 60 / 36 / 94.5%
    #   Qwen3.6-35B-A3B IQ2 + MTP:    280 / 244 / 58 / 27 / 84.8%, but 10.8 GiB
    #   Gemma 4 E4B + MTP:            292 / 243 / 48 / 20
    #   MiniCPM5-2B:                  301 / 293 / 46 / 29
    # Everything past 300 tok/s (Qwen3.5-2B, Gemma E2B, LFM2.5) failed a quarter
    # of the tasks. DFlash on the 4B: 340 raw but 201 on tool-call turns.
    "qwen3.5-4b" = qwen35-4b;
    "gemma-4-26b-a4b" = {
      name = "Gemma 4 26B-A4B (local 32k)";
      weights = unsloth "gemma-4-26B-A4B-it-GGUF" "gemma-4-26B-A4B-it-UD-Q3_K_XL.gguf";
      # Gemma ships its MTP head as a separate file.
      draft = unsloth "gemma-4-26B-A4B-it-qat-GGUF" "MTP/mtp-gemma-4-26B-A4B-it-Q8_0.gguf";
      ctx = 32768;
      # 14.0 GiB. q4_0 KV would save 500 MiB but cost 13% tok/s; ubatch 256
      # saves 180 MiB for free. The Q4 quants leave no room for MTP.
      args = [
        "--spec-type draft-mtp"
        "--spec-draft-n-max 2"
        "--top-k 64"
        "--ubatch-size 256"
      ];
    };
  };

  # work, RTX 4070. The desktop holds 1.8–2.1 GiB (all three monitors hang off
  # this card), and loads start failing around 11.7 GiB total, so the model
  # gets ~9.6 GiB. That buys exactly one upgrade over plain IQ2 32k — MTP, 64k,
  # or the next quant up — never two. MTP wins: same output at 1.5–1.9x the
  # speed, where 64k and IQ3 trade speed or slack for smaller gains.
  #
  # ByteShape quants, score vs BF16 on their benchmark mix / PPL over 200
  # chunks of this repo:
  #   IQ2_XXS 2.56 bpw, 8.2 GiB: 93.0% / 4.448
  #   IQ3_XXS 2.88 bpw, 9.2 GiB: 96.6% / 4.046
  #   IQ3_XS 3.01 bpw (9.6 GiB) and up don't fit at any useful context.
  #
  # Peak own VRAM, measured 2026-09-18 on b11018 (~1.1k tok/s prefill for all;
  # MTP tok/s swings with draft acceptance). KV is ~23 MiB per 1k tokens.
  #   IQ2 32k:        8.5 GiB, 40 tok/s
  #   IQ2 16k + MTP:  8.9 GiB, 57–75 tok/s
  #   IQ2 64k:        9.3 GiB, 39 tok/s
  #   IQ2 32k + MTP:  9.3 GiB, 57–75 tok/s
  #   IQ3 32k:        9.5 GiB, 38 tok/s
  #   IQ2 64k + MTP, IQ2 128k, IQ3 48k, IQ3 + MTP (even at 8k): OOM on load
  # Letting --fit offload layers instead of pinning -ngl 99 always loads, but
  # a few CPU layers drop it to 12–15 tok/s, so a failed load is the better
  # signal that the desktop is using too much VRAM.
  "12" = {
    # Fails to load once the desktop holds more than ~2.4 GiB; without MTP it
    # would tolerate ~3.2.
    "qwen3.8-27b" = {
      name = "Qwen3.8 27B IQ2 (local 32k)";
      weights = byteshape "Qwen3.8-27B-IQ2_XXS-2.56bpw.gguf";
      ctx = 32768;
      # The MTP draft's compute buffer is sized by ubatch; 256 instead of the
      # default 512 saves ~240 MiB with prefill speed unchanged.
      args = kvQ4 ++ mtp ++ ["--ubatch-size 256"];
    };
    # Measured 2026-09-22 on b10964, thinking off, 3 x 24 bash-tool tasks
    # passed / s per 24 / HumanEval+ / tok/s on tool-call turns:
    #   27B IQ2 + MTP (above):  70 / 129 / 86.0% / 69
    #   MiMo Q5_K_M:            66 /  90 / 75.6% / 65
    #   MiMo Q4_K_M:            67 /  57 / 68.9% / 74
    #   Qwen3.5-4B + MTP:       67 /  41 / 76.8% / 191
    # MiMo has no MTP head (the distill dropped it), hence dense-9B raw speed;
    # it also needs a patched chat template for llama.cpp to parse its tool calls.
    "qwen3.5-4b" = qwen35-4b;
  };
}
