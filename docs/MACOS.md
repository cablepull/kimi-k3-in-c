# Running Kimi K3 on macOS (Apple Silicon)

Linux/x86-64 is the reference platform; macOS/arm64 (M-series) is supported. Output is
**byte-identical to the Linux reference** — the hand-written NEON kernels are held
bit-exact to the scalar path (see `intent/adr/001`), so the oracle gate passes unchanged.

## 1. Build

Apple Clang ships no OpenMP runtime, so libomp is a **build requirement**, not an
optimization — without it the build is single-threaded and several times slower:

```sh
brew install libomp
make -j            # or: cmake -B build && cmake --build build -j
```

Both build systems detect Homebrew's libomp automatically and enable the NEON kernels on
arm64 (`intent/adr/002`). `make test` must pass (it needs no model weights).

## 2. Size the machine, then run

Not every Mac has 128 GB. **`--preset auto` sizes the engine to whatever RAM you have**,
from an 8 GB laptop up. The one-line way to get a ready-to-run command:

```sh
./scripts/k3-autotune.sh ~/k3model ~/k3trunk
```

It prints the safe config for this machine and the exact `bin/k3` command, including a
recommended `OMP_NUM_THREADS`. Or drive the engine directly:

```sh
./bin/k3 ~/k3model --trunk ~/k3trunk --preset auto --incremental \
         --tok ~/k3model --prompt "The capital of France is" --gen 16
```

### Check a config without running it

`--dry-run` resolves the memory plan and **exits before allocating anything** — the safe
way to see what a config would do:

```sh
./bin/k3 ~/k3model --trunk ~/k3trunk --preset auto --dry-run
# --dry-run memory plan (nothing allocated):
#   machine        : 137.4 GB total, 123.0 GB available
#   trunk budget   : 76.8 GB
#   expert cache   : 0.5 GB
#   est. peak RSS  : 83.7 GB  (trunk + cache + 6.4 GB fixed)
#   headroom       : 53.8 GB below total
```

## 3. RAM is tunable — and safe by default

The resident set is large (tens to ~100 GB), so an over-aggressive config can push the
machine into swap. **`--preset auto` is deliberately conservative**: it keys off *total*
RAM minus ~28% headroom, never off macOS's reported "available" (which counts reclaimable
cache and overcommits). See `intent/rca/003` — an earlier aggressive port rebooted a
128 GiB Mac.

| knob | effect |
|------|--------|
| `--preset auto` | conservative auto-size for this machine (recommended default) |
| `--headroom-gb N` | shrink/grow the auto safety margin (floor 8 GB) — pin closer to the metal on a *dedicated* machine |
| `--trunk-gb X --cache-gb Y` | explicit budgets; override auto entirely |
| `--dry-run` | print the plan + a swap warning, allocate nothing |

The dry-run flags a plan whose estimated peak RSS crosses ~78% ("tight") or ~85% ("over
safe RAM") of total — macOS swaps well before RSS reaches 100% of RAM. `k3-autotune.sh`
refuses to recommend a flagged config.

## 4. Threads

The bf16 matmul peaks a couple of threads below the core count on Apple Silicon (P/E-core
contention), so `k3-autotune.sh` recommends `OMP_NUM_THREADS = ncpu - 2`. End-to-end the
difference is within noise; tune it only if you care.

## 5. What to expect

On a 128 GiB M-series at the safe auto config, steady-state decode is **~5.8 s/token**.
That is near this hardware's floor: per token the engine streams ~25 GB of MXFP4 experts
from disk (~2.83 s, a hard floor — the experts are never resident), plus ~2.3 s of CPU
compute. More RAM/trunk pinning is flat past the auto point (within noise). The dominant
term is I/O, not compute, so kernel tuning has a small ceiling here — full analysis in the
project's `FINDINGS.md` and `intent/adr/003`.

This is a **base model**: it continues text rather than answering, and there is no chat
template. `--gen N` sets how many tokens to generate; the first token of any run is slow
because it pins the trunk once (~20–30 s), then steady-state kicks in.

## 6. macOS-specific notes

- `--preset auto` reads memory via Mach `host_statistics64` + `sysctl hw.memsize` (there
  is no `/proc/meminfo`).
- Trunk and expert reads use `fcntl(F_NOCACHE)` in place of Linux `O_DIRECT`; large reads
  are clamped to 1 GiB because Darwin rejects a `pread` over `INT_MAX` (`intent/adr` and
  the io/ sources).
- `scripts/k3-doctor.sh` also runs on macOS and reports RAM/disk/toolchain readiness.
