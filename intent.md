---
id: k3-macos-port-2025
title: macOS Port & Performance Sprint for Kimi K3-in-C
created: 2026-08-20
author: (user)
status: active
---

## Purpose

Port kimi-k3-in-c from its Linux x86-64/AVX2-only target to native macOS on Apple Silicon (M-series), while achieving performance within 10% of the published best (≤5.6s/token) at ≥96 GB resident trunk, without regressing correctness or the existing Linux build.

## Constraints (C-1 .. C-8)

| #   | Constraint | Priority |
|-----|------------|----------|
| C-1 | **macOS must boot on any M-series Mac** shipped after 2021. Apple M1/M2/M3 baseline required, M4 welcome where unambiguous instructions set is documented. ARM NEON / SVE2 are mandatory; AMX (Apple Matrix Extensions) is *optional* future work and shall not gate the base port. | must |
| C-2 | **No functional regression.** All existing unit tests (`make test` / `ctest`) pass on Linux x86 before any merge. After a macOS build, same tests pass on macOS with byte-identical bit-exact output for every kernel that has reference fixtures. Floating-point reduction order is *frozen* — only vector partition counts may differ (simulating the same scalar tree). | must |
| C-3 | **No new runtime deps.** The engine already ships zero external libraries; ARM NEON intrinsics are built into `arm_neon.h` and `arm_fp16.h`, which every Apple clang supplies. No Homebrew / vcpkg / conda gate for the user. | must |
| C-4 | **The Linux build is unchanged.** `-mavx2 -mfma` remains default; `-DK3_NATIVE_ARCH` still means x86. The SIMD path selection lives at compile time behind `__aarch64__ && __ARM_NEON`, not runtime detection. A Linux box built with Xcode toolchain gets AVX2, *never* broken NEON code that silently compiles and produces wrong results. | must |
| C-5 | **Benchmark target:** ≤5.6s/token sustained on an Apple Silicon machine with ≥96 GB resident trunk (`--preset server --incremental` or memory-ladder rows ≥96). This matches the published "heavy workstation" floor and is our North star for correctness + speed validation. | must |
| C-6 | **Correctness evidence is mandatory per PR.** Every SIMD kernel gets a fixture test (scalar ↔ neon diff ≤1 ulp on all outputs) before it ships. No "close enough" without the test. | must |
| C-7 | **Memory-map trunk via `mmap` on macOS** (already done on Linux). The streaming trunk ring buffer must remain unchanged at the API level; only the internal page cache pinning strategy may change. On macOS, `MAP_POPULATE` → `MADV_WILLNEED` translation is verified before any perf claim. | should |
| C-8 | **Threading model stays OpenMP but must be verified.** Homebrew `libomp` on Apple Silicon does not guarantee the same work-stealing behavior as GNU libgomp. Thread pinning (`OMP_PROC_BIND`, `OMP_PLACE`) defaults may need tuning per core-to-L2 topology. Document in `docs/MACOS.md`. | should |

## Nudge Dimensions (D-1 .. D-6 — measured by magnetfragnet)

| #   | Dimension | What it measures |
|-----|-----------|------------------|
| D-1 | **ARM SIMD coverage** | Percentage of hot compute kernels (`k3_ops.c` total lines) behind `#if __ARM_NEON`. Target: 100% of matrix multiply, matmul-MXFP4, matmul-bf16, KDA recurrence. |
| D-2 | **Benchmark delta vs target** | Current best s/tok – new best s/tok. Positive = under perf, at/under target = green. |
| D-3 | **Test parity pass rate** | Fraction of pre-existing tests that produce identical output on macOS build (relative to Linux baselines). Target: 100%. |
| D-4 | **macOS compile correctness** | Zero warnings under `-Wextra -pedantic` from Apple clang 15+. Current project compiles warning-free under GCC/Clang on Linux; this checks the port didn't introduce platform-specific UB. |
| D-5 | **Memory resident fraction** | Of trunk (108.8 GB) + experts, what % is actually resident vs streaming under `--preset server`. Target: ≥96%.
  
| #   | Dimension | What it measures |
|-----|-----------|------------------|

## Stories

**Reordered by ADR-003** after measurement showed matmul compute is *not* the
bottleneck (16 vs 18 threads → 9.49 vs 9.60 s/token; expert path is I/O-bound). Priority
now follows the measured per-token budget, not SIMD coverage. `because` the goal (C-5,
s/token) beats the proxy (D-1, SIMD %) when they disagree.

| ID | Story | Priority | Status |
|----|-------|----------|--------|
| S-1 | Scaffold macOS build (CMake + Makefile, libomp, `docs/MACOS.md`) | done-ish | build works; libomp fixed (ADR-002); docs/MACOS.md TODO |
| **S-8** | **Profile the ~2.1 s/token unaccounted** — per-component decoder walls (MLA, KDA, MoE, shortconv, elementwise). Measure before optimize. | **P1** | **NEXT** |
| **S-9** | **Persistent engine** — remove the one-time prefill + per-call trunk-pin; biggest user-visible latency win, byte-identical | P2 | TODO |
| **S-10** | **Attack the expert-I/O floor (2.83 s/token)** — int8/quantized experts, deeper prefetch overlap, device queue-depth. The single largest per-token term. | P3 | TODO |
| S-4 | Vectorize the hot path P1 identifies (likely KDA recurrence / MLA attention), bit-exact per ADR-001 | P3 | gated on S-8 |
| S-3 | NEON bf16 trunk matmul (`k3_matmul_bf16` path), 0-ulp vs `bench_kernels` FNV1a | P4 | demoted — only ~1 s, do after S-8 confirms it's on the critical path |
| S-7 | Config sweep: `OMP_NUM_THREADS`×`--trunk-gb`×NEON → RAM-vs-speed Pareto frontier | P4 | TODO |
| ~~S-2~~ | ~~NEON MXFP4 expert matmul~~ | **won't-do** | I/O-bound; ~0 end-to-end gain (ADR-003 finding 3). Reopen only if S-8 reverses it. |
| S-6 | Thread pinning (`OMP_PROC_BIND`/`OMP_PLACES`) | doc-only | washes out end-to-end; document in docs/MACOS.md, not a build story |
| S-5 | NEON RMSNorm / ShortConv / elementwise | opportunistic | RMSNorm NEON already landed (bit-exact); rest only if P1 shows they matter |

### Path 2 — batched GPU throughput server (branch `gpu-batched-server`)

`because` ADR-006 measured GPU at 10–200× for GEMM (M≥16) while ~parity for single-token
decode: throughput (many concurrent requests / heavy prefill), not single-stream latency, is
where GPU pays. Driven by the loop in `intent/loops/gpu-throughput.md`. Abandons
bit-exactness for the GPU path (explicit correctness-regime change) while the CPU
single-stream path stays byte-identical.

| ID | Story | Priority | Status |
|----|-------|----------|--------|
| S-P2-1 | ADR: batched-server architecture + tolerance-based correctness regime | P1 | TODO |
| S-P2-2 | Prereq gate: detect Xcode/metal compiler; MPS-only vs full-shader plan | P1 | TODO |
| S-P2-3 | Batched decode harness — run M token-streams through the decoder together | P2 | TODO |
| S-P2-4 | GPU bf16 trunk GEMM via MPS, resident weights, tolerance test | P2 | TODO |
| S-P2-5 | MXFP4 expert dequant + GEMM custom Metal shader (needs full Xcode) | P3 | TODO — gated on Xcode |
| S-P2-6 | Dynamic request batching / scheduler (merge concurrent decode steps) | P3 | TODO |
| S-P2-7 | Tolerance validation harness (replaces exact-token oracle for the GPU path) | P2 | TODO |
| S-P2-8 | Throughput benchmark: tokens/sec vs batch vs CPU single-stream | P3 | TODO |

## Design Decisions (ADR-001 .. ADR-NNN)

See `adr/` for individual design decisions.
