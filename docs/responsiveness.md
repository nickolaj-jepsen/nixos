# Responsiveness under load

What keeps the desktop usable while builds, tests and agents saturate the machine:

- **CPU:** the kernel's EEVDF scheduler with systemd's slices
  (`modules/system/responsiveness.nix`). No sched_ext scheduler: they ignore the weights.

  | Slice              | CPUWeight | What is in it                                                      |
  | ------------------ | --------- | ------------------------------------------------------------------ |
  | `session.slice`    | 1000      | niri, dms, pipewire, the portals, niriusd, niri-dynamic-workspaces |
  | `app.slice`        | 100       | everything launched: apps, terminals and the agents in them        |
  | └ Firefox's scope  | 1000      | outranks the rest of `app.slice`, which then shares per app        |
  | `background.slice` | 20        | daemons nobody waits on: agent-hub, llama-swap, devmon             |
  | `nix.slice`        | 20        | nix builds                                                         |

  Terminals and agents may lag under load; niri and Firefox should not.

- **Memory:** zram at half of RAM (`modules/system/zram.nix`), earlyoom killing one build or
  test worker once memory and swap are both short, and systemd-oomd as the last resort
  (`modules/system/oomd.nix`). The DMS bar shows `RAM% · swap%`; a full zram is the warning.

To check: `journalctl --user -t niri | grep 'lagging behind'` for input lag,
`cat /proc/pressure/{cpu,memory,io}`, `systemd-cgtop`, `journalctl -u earlyoom`.

## Setting a repo up for parallel work

CPU needs no help: extra workers slow other work in `app.slice`, never the compositor, and a
single run should use every core. Memory is what hurts when several runs overlap: workers ×
memory per worker, times the runs.

1. **Leave parallelism at the tool's default** unless a worker is memory-heavy.
2. **Budget memory-heavy pools** (vitest forks, type-checker workers, browser pools, linkers) so
   one run peaks around 8 GB: `workers = min(cores, 8 GB / peak memory per worker)`.
3. **Always leave an override** in the environment, read by the repo's own config, e.g.
   `SJUSK_TEST_WORKERS` in sjusk's `vitest.config.ts`.

| Tool         | Where the worker count lives                                                                  |
| ------------ | --------------------------------------------------------------------------------------------- |
| vitest 4+    | `test.maxWorkers` in the config; `VITEST_MAX_WORKERS`                                         |
| vitest 3     | `poolOptions.forks.maxForks` / `threads.maxThreads`; `VITEST_MAX_FORKS`, `VITEST_MAX_THREADS` |
| cargo        | `[build] jobs` in `.cargo/config.toml`; `CARGO_BUILD_JOBS`                                    |
| go           | `GOFLAGS=-p=N` for packages built at once                                                     |
| tsc / tsgo   | tsc is single-threaded; tsgo takes `--checkers N`                                             |
| turbo        | `--concurrency N` (or a percentage) in the task's script                                      |
| make / ninja | `-j N`                                                                                        |
