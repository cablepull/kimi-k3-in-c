# ADR-003: Performance priority is I/O and attention, not matmul NEON

## Status
Accepted (supersedes the story ordering in intent.md S-1..S-7)

## Status of stories
This ADR reorders and rescopes the stories. `intent.md` is updated to match; the
original ordering is preserved here for the record.

## Context
Cites C-5 (benchmark target) and the D-1 dimension ("ARM SIMD coverage … 100% of matmul").
The intent's stories put SIMD matmul first: **S-2 = NEON MXFP4 expert matmul**, then
**S-3 = NEON bf16 trunk matmul**, then S-4 = KDA. That ordering assumed compute — and
specifically the matmuls — is the bottleneck. Measurement contradicts the assumption:

1. **Compute is not the bottleneck it was thought to be.** The premise "≈10 s/token
   compute" came from a CMake build that silently ran single-threaded (RCA-002).
   Multi-threaded, `bench_kernels` shows bf16 matmul at **114 GFLOP/s** (16 threads),
   making real trunk-matmul compute ≈1.0 s/token, not 11.

2. **Matmul speed does not move the end-to-end number.** Natural experiment: the same
   full run at 16 threads (bf16 matmul's fastest point, 114 GFLOP/s) vs 18 threads
   (107) gave **9.49 vs 9.60 s/token** — indistinguishable. A ~7% matmul change is
   invisible end-to-end because the matmul is ~1 s of a ~5.9 s token.

3. **The expert path is I/O-bound.** Per token the engine reads ~25.8 GB of experts
   (2.83 s at 9.1 GB/s) and computes them in ~0.4 s. NEON on the MXFP4 expert matmul
   (S-2, the *first* story) optimizes a term that is already 7× smaller than the read
   it hides behind. Expected end-to-end gain: ≈0.

4. **The real budget** (5.9 s steady): expert I/O ~2.83 s (hard floor) + bf16 trunk
   compute ~1.0 s + expert compute ~0.4 s (hidden) + **~2.1 s unaccounted** (attention
   MLA, KDA glue, memory movement, non-overlap). The largest addressable term after the
   I/O floor is the unaccounted ~2.1 s, which no matmul story touches.

## Decision
1. **Demote S-2 (NEON MXFP4 expert matmul) to "won't do unless profiling reverses this."**
   It is I/O-bound; the SIMD-coverage dimension D-1 ("100% of matmul") is amended — SIMD
   coverage is not a goal in itself, only where it moves the measured token time.
2. **New P1: profile the ~2.1 s unaccounted before any further kernel work.** Instrument
   the decoder layer (per-component walls: MLA, KDA, MoE, shortconv, elementwise) and
   attribute the 5.9 s exactly. Measure before optimize.
3. **New P2: persistent engine.** Removes the one-time ~39 s prefill and ~1–2 min
   per-call trunk-pin from every request — the biggest *user-visible* latency win, and
   byte-identical. Independent of per-token compute.
4. **New P3: the expert-I/O floor (2.83 s) is HARDER than first thought.** Corrected: the
   experts already ship as **MXFP4 (4-bit)** — int8 would *double* bytes, not halve them.
   Fewer bytes/token would need fewer experts (a model change) or caching (defeated by the
   flat-usage router, per the engine's own comments). So 2.83 s is close to a true floor;
   the only I/O levers are a faster device or deeper prefetch overlap (already ~80% on the
   trunk). This strengthens the case that the remaining real win is **P2 (persistent
   engine, time-to-first-token)**, not steady-state s/token.
5. **bf16 trunk matmul NEON (former S-3) stays, demoted to P4** — real but ~1 s, and only
   worth it once P1 confirms trunk compute is on the critical path. Held to ADR-001
   0-ulp bit-exactness, validated against the `bench_kernels` FNV1a hash.
6. **Thread count is a documented config, not a story.** bf16 peaks at 16 threads but
   washes out end-to-end (finding 2); record `OMP_NUM_THREADS`/`OMP_PROC_BIND` in
   docs/MACOS.md and move on.

## Consequences
- The sprint stops spending effort on SIMD coverage for its own sake and redirects to the
  terms that actually dominate the token: I/O and attention.
- D-1 (SIMD coverage %) is demoted from a target to a diagnostic; D-2 (benchmark delta)
  remains the real scoreboard.
- Risk: P1 profiling may show the ~2.1 s is memory-bandwidth or non-overlap, i.e. not
  cleanly optimizable — in which case the honest ceiling on this machine is near the
  I/O floor and the win is P2 (persistent engine) + P3 (fewer expert bytes).

## Alternatives considered
- **Keep the matmul-first ordering (do S-2/S-3 as written).** Rejected: finding 2 is a
  direct measurement that matmul speed doesn't move the token; finding 3 shows S-2 is
  I/O-bound. Proceeding would burn effort for ≈0 measured gain — the exact failure mode
  the "measure before optimize" discipline exists to prevent.
- **Trust D-1 (100% SIMD coverage) as the goal.** Rejected: coverage is a proxy; the PRD's
  actual goal (C-5) is s/token. When the proxy and the goal disagree, the goal wins.

## Evidence
- `bench_kernels` thread sweep (ADR-002): bf16 10.3→114 GFLOP/s, peak at 16 threads.
- Full-engine 16 vs 18 threads: 9.49 vs 9.60 s/token (`scratchpad/threads16.log` vs
  `trunk-parallel.log`).
- Per-token budget from `trunk-parallel.log`: experts 59.6 s / 16 = 3.7 s device, 2.83 s
  on critical path; trunk 50.5 s / 16 with 80% overlap.
- FINDINGS.md §3b (external working notes).
