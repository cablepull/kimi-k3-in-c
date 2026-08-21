# ADR-007: Batched-server architecture, correctness regime, and the disk-I/O throughput ceiling

## Status
Accepted (S-P2-1), but its "disk-bound ceiling" premise is **CORRECTED by RCA-004** — see
the Correction note below. The reorder-and-measure-first decision stands and is reinforced.

## CORRECTION (RCA-004): experts have strong locality; the ceiling is a RAM question
The ceiling analysis below assumed the router uses experts ~uniformly (so caching is
near-useless). `tools/sim_cache.py` on the committed 68-token trace disproves that:
**90% of expert requests are repeats**, the active working set is **~176 GB (not 1.45 TB)**,
and a 192 GB expert cache reaches **90% hit → 2.58 GB/token → ~2.09 s I/O** (vs 13.4 s
uncached — a 10x drop). So expert I/O is NOT a fixed disk floor; it collapses once the
working set is resident. Consequences:
- **The real architecture is: hold trunk (108 GB) + expert working set (176 GB) resident
  (~285 GB) and run GPU on it.** Then the token is compute-bound and GPU's 200x GEMM +
  batching becomes the actual throughput lever. This needs a ~384 GB+ machine.
- **On 128 GB** you hold a slice: ~128 GB cache is 49% LRU hit, but BELADY shows **85% is
  achievable** — the engine's LRU leaves a large gain on the table (a better cache policy,
  e.g. frequency/pin-hot, is a real optimization). Partial (~2x) here.
- The trunk-vs-cache tradeoff the auto-sizer assumes ("trunk worth ~70x expert cache") was
  derived under the same flat-usage assumption and must be re-evaluated: below the
  working-set threshold the expert cache plateaus (36-49%), but crossing it is worth ~10x.
The rest of this ADR (architecture, correctness regime, measure-first) stands.

## Context
Path 2 aims to turn the single-stream engine into a batched throughput server, on the
strength of ADR-006's measurement that GPU GEMM is 10-200x for M>>1. But throughput has a
harder ceiling than compute, and it must be stated before any code is written.

**The throughput ceiling is disk bandwidth, not GPU compute.** Every generated token
activates 16 of 896 experts per layer, and those experts stream from a 1.5 TB checkpoint
that does not fit in 128 GB RAM (they are already MXFP4/4-bit; caching is defeated by the
router's flat expert usage — engine's own comments). Measured: ~13.6 GB of experts read
per token, disk ~9.1 GB/s parallel.

    aggregate ceiling = 9.1 GB/s / 13.6 GB/token ~= 0.67 tokens/s
    single-stream now = 1 / 5.8 s ~= 0.17 tokens/s
    => headroom before the disk wall ~= 3.9x, NOT the GPU's 200x

Batching amortizes weights and lets the GPU's GEMM shine, but each token still needs its
own experts off disk, so aggregate token throughput cannot exceed ~0.67 tok/s on this
machine regardless of batch size or GPU. GPU + batching only *reaches* that ceiling; it
cannot pass it.

## Decision

### Architecture (target)
A dynamic-batching inference server:
- N concurrent request streams. At each decode step, gather the pending token from every
  active stream into a batch of M, run ONE batched forward pass, scatter results back.
- Batched forward: bf16 trunk GEMM (MPS, resident/unified-memory weights) and MXFP4 expert
  GEMM (custom Metal shader for dequant+matmul) for the M-token batch; attention (KDA/MLA)
  batched over M.
- The streamed expert cache stays; a batched step reads the UNION of experts its M tokens
  route to (per-token expert bytes ~unchanged, so the disk ceiling above holds).

### Correctness regime (the explicit fork)
- The **CPU single-stream path stays byte-identical** and its exact-token oracle MUST keep
  passing. It is the reference.
- The **GPU/batched path is tolerance-based**, not bit-exact (GPU FP diverges — ADR-006
  measured 1.35e-3 rel on one matmul). Validation is a harness (S-P2-7) that reports, vs
  the CPU reference on a fixed prompt set: (a) greedy-token agreement rate, (b) per-step
  logit cosine similarity, (c) perplexity delta. Ship thresholds, not "looks fine".

### Reordering: measure before the GPU build
Because the ceiling is disk-bound at ~3.9x, the GPU may be unnecessary: if a **CPU**
dynamic-batching scheduler already saturates the disk (overlapping compute across streams
while I/O is in flight), GPU adds nothing here. GPU matters ONLY if batched CPU compute
cannot keep up with disk delivery. So:
1. **S-P2-3 first (CPU dynamic batching)** + a throughput probe: measure tokens/s as a
   function of concurrent streams on CPU. Find where it plateaus.
2. If it plateaus AT the disk ceiling (~0.67 tok/s) → compute is not the bottleneck; the
   GPU port (S-P2-4/5) is **not worth it on this machine**; ship the CPU batched server.
3. If it plateaus BELOW the disk ceiling because CPU compute can't keep up → GPU is
   justified to close the gap; proceed with S-P2-4/5.

## Consequences
- Honest ceiling on the table before investment: path 2 is a **~3.9x aggregate throughput**
  play at best on this 128 GB machine, not orders of magnitude.
- The ceiling LIFTS on hardware that can hold experts resident (a 512 GB+ box) or with a
  smaller expert format — noted for a different machine, out of scope here.
- The GPU port is now *conditional* on the S-P2-3 measurement, saving a possible second
  wasted port (cf. ADR-006's single-stream no-go).
- Two correctness regimes coexist: exact CPU reference, tolerance-based GPU/batched.

## Alternatives considered
- **Build the GPU batched path straight away.** Rejected: the disk ceiling may make GPU
  compute irrelevant here; measure CPU batching first (the session's measure-before-optimize
  rule, which already killed the matmul-NEON and single-stream-GPU investments).
- **Hold experts resident to lift the ceiling.** Out of scope: 1.5 TB doesn't fit in
  128 GB; belongs to a bigger-RAM deployment.

## Evidence
FINDINGS.md §3b (per-token expert bytes, disk rate), ADR-006 (GPU batch-crossover +
bit-exactness delta), the ceiling arithmetic above (reproduced in the iteration-1 log).
