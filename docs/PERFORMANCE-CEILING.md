# Performance ceiling on Apple Silicon (128 GB)

Where Kimi K3 lands on a maxed M-series Mac, what limits it, and what would move it —
so nobody re-derives this the hard way. Backed by the ADRs/RCAs/research referenced below.

## The number
On a 128 GB M5 Max (40-core GPU), steady-state decode is **~5.8 s/token**, and that is
**near this hardware's floor**. The engine is well-optimized for it.

## Why — the per-token budget
| term | ~s/token | nature |
|------|---------:|--------|
| expert I/O | ~2.83 | **hard floor** — 16/896 experts per layer stream from a 1.5 TB checkpoint that doesn't fit in RAM |
| compute (matmul, KDA, attention) | ~2.3 | scalar/NEON on 18 cores; bandwidth-bound GEMV |
| trunk I/O | ~0.6 | mostly overlapped after the parallel-reader fix |

## What was tried, and why none of it moves 128 GB
Three independent levers were investigated and measured (not assumed):

1. **Compute kernels (NEON / threads / GPU)** — the per-token matmul is a **GEMV**
   (one token, each weight used once), so it is *bandwidth*-bound, not FLOP-bound. The CPU
   already saturates unified-memory bandwidth; the GPU is ~1.2× on it (measured), and
   16-vs-18-thread washes out. The 40-core GPU's 200× only appears for **GEMM** (batched /
   many tokens), which is a throughput regime, not single-conversation latency.
   → `intent/adr/006`.

2. **A smarter expert cache (LFU vs LRU)** — experts have strong locality (90% reuse,
   ~176 GB working set — `intent/rca/004`), and LFU is a huge policy win (**80% vs LRU's
   49% at a 128 GB cache** — `intent/research/001`). BUT the trunk (108 GB, no locality,
   read every token) must stay resident, leaving ~2 GB for the cache, where LFU = LRU. The
   LFU win needs a ≥64 GB cache.

3. **Memory config (`--trunk-gb`)** — flat across the usable range; RAM-ceiling-capped.

## The common wall: RAM
All three promising levers need more RAM than 128 GB:

    LFU expert cache (80% hit):  trunk 108 + cache 126  = ~234 GB
    GPU compute-bound token:     trunk 108 + working set 176 = ~285 GB

128 GB holds the trunk **or** a useful expert cache, **not both**. On a ≥256 GB machine
(if one ever ships), the LFU cache + GPU compute + request batching all pay off *together*
and K3 becomes both much faster and high-throughput. The staged work for that lives on the
`expert-cache`, `metal-gpu`, and `gpu-batched-server` branches (research, spikes, ADR-007's
batched-server design, and a `/loop` prompt), ready to build when the hardware exists.

## What IS shipped for 128 GB (on `main`)
- macOS/arm64 port, output byte-identical to the Linux reference
- OpenMP + bit-exact NEON; parallel-chunked trunk reader (~3× on trunk reads)
- Safe, tunable auto-sizing (`--preset auto`, `--dry-run`, `--headroom-gb`,
  `scripts/k3-autotune.sh`) — never swaps the host
- `docs/MACOS.md` for build/run

## Bottom line
128 GB Apple Silicon runs the full 2.78T model correctly at ~5.8 s/token, near its floor.
Going meaningfully faster is a RAM problem, not a software one — and the software to exploit
more RAM is already researched and staged.
