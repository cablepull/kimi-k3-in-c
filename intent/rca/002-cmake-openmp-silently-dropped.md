# RCA-002: CMake build silently single-threaded; invalidated the compute premise

**Status:** Resolved
**Created:** 2026-08-20

## Summary
The macOS CMake build (`build-macos-arm/`) linked no OpenMP runtime, so it and
`bench_kernels` ran single-threaded. This was invisible: the build succeeded, tests
passed, and `bench_kernels` reported plausible-looking ~10 GFLOP/s numbers. Those
single-core numbers drove the sprint's central assumption — "compute is a ~10 s/token
bottleneck, so NEON is the lever." Multi-threaded, compute is ~2.3 s/token; the premise
was wrong by ~4×.

## Root Cause
`find_package(OpenMP)` fails on Apple Clang (no `-fopenmp` advertised), setting
`OpenMP_C_FOUND=FALSE`. The link was guarded `if(OpenMP_C_FOUND)`, so a *failed* probe
degraded silently to a single-threaded build instead of erroring. No `otool -L` /
thread-scaling check existed to catch it.

## Violated Requirement
- C-8 ("threading model stays OpenMP but must be *verified*"). It was neither wired nor
  verified on macOS.
- Implicit: performance measurements must reflect the shipping (Makefile, threaded)
  build; the CMake build silently diverged from it.

## Resolution
- ADR-002: CMake falls back to Homebrew libomp on Apple, or warns loudly. Never silent.
- Verified by `otool -L` (libomp now linked) and a thread sweep (flat → near-linear to
  16 threads).
- New guard for the sweep work: every perf claim states its thread count and is taken
  from a binary confirmed to link libomp.

## Assumptions
| ID | Assumption | Basis | Status |
|----|-----------|-------|--------|
| A-1 | The 5.9 s/token baseline is valid | taken from Makefile `bin/k3`, which links libomp (`__kmpc_*` symbols present) | Held |
| A-2 | 16 threads may beat 18 on the real engine | bench bf16 peaks at 16 (114) vs 18 (107); P/E-core contention | To be confirmed on full engine |
| A-3 | The ~2.1 s/token unaccounted is attention/KDA | subtraction after expert I/O + matmul; not yet directly profiled | Open — profile next |
