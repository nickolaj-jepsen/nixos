# Local LLM: Qwen3.8-27B on the macbook

## Why

A local model earns its keep on exactly two jobs, both **personal** — journals,
finances, health, side projects:

- **Privacy** — material that shouldn't go to an API. Note this is a _residual_
  category: `fireproof.claude-code.work.enable` means work code already goes to
  Anthropic, so this is about personal data, not a blanket no-API policy.
- **Availability** — a competent assistant when the WAN is down but the LAN is up.

Everything hard still goes to Claude. The quality bar here is moderate: recall,
chat, summarising a document. That bar is what makes a 4-bit 27B acceptable.

The one assumption measurement can't test: 27B was chosen over a faster 14B for
**offline world knowledge**, which is the thing parameter count buys and small
models can't fake.

## Decisions

|           | Choice                                              | Why                                                                           |
| --------- | --------------------------------------------------- | ----------------------------------------------------------------------------- |
| Host      | macbook (M5 Pro, 24 GB)                             | Only box in the fleet that holds a good 27B quant                             |
| Model     | `unsloth/Qwen3.8-27B-GGUF` → `UD-Q4_K_XL` (17.9 GB) | Best quality-per-byte that fits a headless 21 GB wired limit                  |
| Runtime   | llama.cpp `llama-server`, Metal                     | Mature OpenAI-compatible server; wins prefill, which is what long prompts are |
| Packaging | **Homebrew** (`homebrew.brews`)                     | nixpkgs' darwin `llama-cpp` ships a broken Metal build — see below            |
| Vision    | text-only, no mmproj                                | Both jobs are text; keeps the full KV budget; least-tested code path avoided  |
| Thinking  | off by default (`--reasoning-budget 0`)             | At 14.8 tok/s a 2k-token thought is ~135 s to first word                      |
| Context   | 64k at `q8_0` KV (f16 caps at ~32k)                 | Measured, not estimated — see KV budget                                       |
| Weights   | outside the store, pinned revision                  | 18 GB in the system closure would drag `just check` and `nix copy`            |
| Exposure  | LAN bind + API key from `.rekey-hm`                 | Machine lives lid-closed on a desk, so the travel risk is accepted            |
| Client    | none yet                                            | Measure real tok/s first; the number decides what frontend is worth building  |

Pinned revision: `408fcc1807ab264d8cd644a7c4c0f58fbd32eebc`
(`Qwen3.8-27B-UD-Q4_K_XL.gguf`), fetched to `~/llm/models`.

## The model — verified from GGUF metadata

The header says what the marketing doesn't:

```
general.architecture       = qwen35        ← not a new arch
general.name               = Qwen3.8-27B
qwen35.block_count         = 65
qwen35.attention.head_count_kv = 4
qwen35.attention.key_length    = 256
qwen35.attention.value_length  = 256
qwen35.full_attention_interval = 4
qwen35.ssm.state_size          = 128
```

**Qwen3.8-27B ships as the existing `qwen35` architecture.** This was the riskiest
assumption in the plan and it resolves favourably: any llama.cpp with the Qwen3.5
hybrid support already handles it. Confirmed present in both b9890 (brew) and
b10430. No new-architecture gamble.

`full_attention_interval = 4` means 16 of 65 layers carry a KV cache; the other 49
hold fixed-size DeltaNet state that doesn't grow with context.

## KV budget — arithmetic, not estimate

```
per token = 16 layers × 4 kv-heads × (256 + 256) × 2 B = 64 KiB   (f16)
```

| Context | f16       | q8_0      |
| ------- | --------- | --------- |
| 32k     | 2.1 GiB ✓ | 1.1 GiB ✓ |
| 64k     | 4.2 GiB ✗ | 2.2 GiB ✓ |

Against the measured 4.6 GB budget (see below), `q8_0` at 64k is comfortable and f16
at 64k is borderline. `q8_0` remains the default: it buys headroom for compute
buffers at near-zero quality cost, and `q4_0` would degrade exactly the long-range
recall the window exists for.

## Memory: the wired limit is load-bearing

Metal defaults to ~75% of RAM (18 GB of 24), sized to leave room for a desktop
you're using. A 17.9 GB model overruns it during graph compute:

```
error: Insufficient Memory (kIOGPUCommandBufferCallbackErrorOutOfMemory)
```

That is the observed failure with the default limit and apps open — the model
loads, then dies on the first decode. `iogpu.wired_limit_mb = 21504` plus a closed
desktop is not a tuning nicety, it is the difference between working and not.

Measured with `iogpu.wired_limit_mb = 21504`, Metal reports a working set of
**22548.58 MB** — slightly above the wired limit, and more headroom than the
75%-rule estimate suggested:

```
 22.5  recommendedMaxWorkingSetSize at wired_limit_mb = 21504
-17.9  UD-Q4_K_XL weights (16.68 GiB)
──────
  4.6  GB for KV cache + compute buffers
```

So 64k at `q8_0` (2.2 GiB) sits comfortably rather than at the edge, and 64k at
f16 (4.2 GiB) is borderline-feasible after all. Q5 (21+ GB) still does not fit.

## Why Homebrew and not nixpkgs

nixpkgs' darwin `llama-cpp` produces a **Metal-less binary**:

```
E ggml_metal_library_init_from_source: error compiling source
W ggml_metal_device_init: - the tensor API is not supported in this environment - disabling
```

No `.metallib` in the output. The embed path works by `sed`-inlining
`ggml-common.h` and `ggml-metal-impl.h` into the shader source and `.incbin`-ing
the result; that isn't producing a usable blob, so ggml falls back to compiling
shaders at runtime and fails. Adding the renamed `GGML_METAL_EMBED_LIBRARY` flag
did not fix it.

This is **pre-existing and not caused by a version override** — stock b10063 from
`pkgs.unstable` fails identically. The Homebrew bottle initialises Metal cleanly
and reaches graph compute:

```
ggml_metal_device_init: has tensor            = true
ggml_metal_device_init: use residency sets    = true
ggml_metal_device_init: recommendedMaxWorkingSetSize = 19069.67 MB
```

`has tensor = true` is the bigger deal than it looks: that is the M5
neural-accelerator path, which the nixpkgs build reports as
`tensor API is not supported in this environment - disabling`. Homebrew doesn't
merely restore Metal, it restores the fast path this chip exists for.

(That 19069.67 MB working set is at the _default_ wired limit — already above the
18 GB the 75%-of-RAM rule implies, but still short of what the model needs. Raising
the limit to 21504 takes it to 22548.58 MB.)

Two corrections to earlier assumptions worth recording:

- **Homebrew is not bleeding-edge here.** Its bottle is b9890 — _older_ than
  `pkgs.unstable`'s b10063. It works because `qwen35` predates Qwen3.8, not
  because it's fresh.
- **Upstream's flake is unusable on darwin.** `nix run github:ggml-org/llama.cpp`
  fails on `darwin.apple_sdk_11_0`, removed from nixpkgs. There is no
  zero-repo-changes test path.

For the record, if the nixpkgs route is ever revisited, a version bump needs both
`src` and `npmDepsHash` overridden (the web UI's npm FOD hash is pinned to the old
source) — and it still won't have Metal.

## Version reference

| Source             | Locked     | `llama-cpp` | Metal |
| ------------------ | ---------- | ----------- | ----- |
| `nixpkgs`          | 2026-05-26 | b9190       | ✗     |
| `nixpkgs-unstable` | 2026-07-19 | b10063      | ✗     |
| Homebrew bottle    | —          | b9890       | ✓     |
| upstream latest    | 2026-08-14 | b10430      | n/a   |

The Gated DeltaNet Metal fix (a memory-coalescing bug in the fused GDN kernel,
worth a 39% regression) landed in b8333, so every build here is past it.

## Implementation

- `modules/base/fireproof.nix` — `fireproof.llm.*` options.
- `modules/programs/llama-server.nix` — darwin half: the brew, a launchd **user
  agent** (not a daemon, so the HM-decrypted API key is readable), the
  `iogpu.wired_limit_mb` sysctl, and firewall pre-authorisation.
- `hosts/macbook/host.nix` — `fireproof.llm.enable = true`.

Still outstanding:

- `secrets/hosts/macbook/.rekey-hm/llama-api-key.age` + `just secret-rekey`, then
  point `fireproof.llm.apiKeyFile` at it. Until then the endpoint is unauthenticated.
- A `just` recipe for the pinned weights fetch.
- Lid-close sleep: `pmset disablesleep` or a `caffeinate` wrapper. Not yet declared.

## macOS gotchas

- **`iogpu.wired_limit_mb` does not survive reboot.** Re-applied in
  `system.activationScripts.postActivation`.
- **Lid-close sleeps the machine mid-generation**, regardless of
  `power.sleep.computer = "never"` — that knob is lid-open only.
- **The app firewall's allow-dialog blocks unattended launchd services.** Stealth
  mode is on and the firewall is enabled, but it is per-application, not
  per-network — once `llama-server` is allowed it is allowed everywhere.
- **`--api-key` as a flake literal leaks** into a world-readable `/nix/store` path
  _and_ into `ps` output. Key-file form only.
- **`llama-cli` no longer accepts `-no-cnv`**; it falls into interactive mode and
  spins against EOF. Use `llama-completion` for one-shot generation.

Sustained decode on a laptop chassis will thermally throttle. Fine for interactive
turns, less fine for long batch runs.

## Rejected alternatives

- **MLX / `mlx-vlm`** — Metal-native, ~10% less memory, and what Apple optimises the
  M5's neural accelerators for. But `mlx-vlm` releases don't list Qwen3.8 yet, the
  HF conversions are community jobs against 0.6.3, and a silent architecture
  fallback produces fluent garbage. Its serving story is also thinner than
  `llama-server`, and MLX loses on prefill. Revisit when a release names Qwen3.8 —
  and note the nixpkgs Metal bug makes MLX relatively more attractive than it looked.
- **LM Studio** — closed-source with telemetry. Wrong thing to point journals at.
- **Ollama** — now MLX-backed on Apple Silicon and easiest to set up, but its Go
  wrapper has historically cost roughly half of raw llama.cpp throughput.
- **desktop (RTX 5070 Ti)** — 896 GB/s against the Mac's 307, so ~3x faster on
  anything that fits, with native FP4 tensor cores. But 16 GB is the wrong side of
  the cliff for a 27B: NVFP4 weights leave ~1.5 GB for KV, which kills the
  long-document use case. A 27B needs 24 GB.
- **homelab (GTX 970, 4 GB)** — not a contender for inference. Still the natural
  home for a frontend later, since it's always on and already runs nginx.

## Measured

`llama-bench`, b9890, full Metal offload, `wired_limit_mb = 21504`:

| test          | t/s               |
| ------------- | ----------------- |
| pp512 prefill | **378.83 ± 0.41** |
| tg64 decode   | **14.81 ± 0.02**  |

Model loads as `qwen35 27B Q4_K - Small`, 16.68 GiB, 27.32 B params, backend
`BLAS,MTL`.

Decode is **87% of the memory-bandwidth ceiling** (307 GB/s ÷ 17.9 GB ≈ 17 t/s), so
this is a well-tuned path with little left on the table — no amount of flag-fiddling
buys much more. The remaining lever is a smaller quant, which trades quality for
speed roughly linearly.

### The benchmark number is conditional — `--mlock` is not optional

Served from the launchd agent with a normal desktop session running, the same model
measured **1.1–1.4 tok/s decode and ~2 tok/s prefill** — a 10x collapse. Cause:
`llama-server` RSS had fallen to 1.8 GB against a 17.9 GB model. macOS reclaims
mmap'd weight pages as soon as anything else wants memory (0.1 GB free, 3 GB swap in
use at the time), so every token was streaming from disk.

Raising `iogpu.wired_limit_mb` lets Metal _allocate_; it does not stop the kernel
_evicting_. `--mlock` is what keeps the weights resident, and the module sets it by
default (`fireproof.llm.mlock`).

This is the empirical case for the appliance decision: with ~18 GB locked there is
no meaningful desktop session left on a 24 GB machine. Serving and using this
laptop are mutually exclusive, and that is the intended trade, not a regression.

What the numbers mean in use:

- **Reading a long document**: 378 t/s prefill → a 20k-token journal costs ~53 s
  before generation starts, once per session if the KV cache is reused.
- **Thinking is expensive**: a 2000-token thought is ~135 s before the first visible
  word. This validates `--reasoning-budget 0` as the default.
- **Chat is comfortable**: 14.8 t/s outruns human reading speed.
- **Agent loops are not**: many turns, each paying prefill on a growing prompt.
  Confirms the decision to point this at a chat frontend rather than an agent harness.

## Exit criteria

Threshold was ~8 tok/s. **Passed at 14.81** — proceed.

The fallback, had it failed, was a smaller model or patience, **not** the 5070 Ti.
