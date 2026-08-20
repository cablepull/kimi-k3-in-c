# ADR-002: The macOS CMake build must wire libomp explicitly

## Status
Accepted

## Context
Cites C-3 ("no new runtime deps") and C-8 ("threading model stays OpenMP but must be
verified … document in docs/MACOS.md"), and RCA-002.

`find_package(OpenMP)` **fails on Apple Clang**: the compiler does not advertise
`-fopenmp`, so CMake sets `OpenMP_C_FOUND=FALSE` and — because the link was guarded by
`if(OpenMP_C_FOUND)` — the build silently dropped all threading. Evidence:
`otool -L build-macos-arm/k3` linked no libomp; `bench_kernels` showed **zero thread
scaling** (10.2 GFLOP/s at 1 thread, 10.2 at 18). Every performance number produced from
the CMake build — including the premise that compute is a ~10 s/token bottleneck — was
single-core and wrong. The Makefile build (`bin/k3`) was unaffected because it wires
libomp by hand (`-Xpreprocessor -fopenmp … -lomp`), which is why the real 5.9 s/token
measurements were valid.

## Decision
When `find_package(OpenMP)` fails on Apple, fall back to Homebrew's libomp: locate it via
`brew --prefix libomp`, and if `libomp.dylib` exists, define an imported
`OpenMP::OpenMP_C` target with `-Xpreprocessor -fopenmp`, the include dir, and the dylib —
mirroring the Makefile. If libomp is absent, emit a loud `WARNING` that the build will be
single-threaded (never fail silently). No new dependency (C-3): libomp is the same runtime
the Makefile already requires.

## Consequences
- Wins: CMake builds are multi-threaded and match the Makefile; `bench_kernels` and any
  config sweep report real numbers. Measured after the fix: bf16 matmul **10.2 → 114
  GFLOP/s** (16 threads), mxfp4 **10.3 → 78.8** (18 threads).
- Costs: none functional. One Homebrew probe at configure time on macOS.
- Follow-on: thread count is now a tunable. bf16 peaks at 16 threads and regresses at 18
  (P/E-core contention on M-series), so `OMP_NUM_THREADS`/`OMP_PROC_BIND` become
  sweep axes (C-8).

## Alternatives considered
- **Require the user to pass `-DOpenMP_C_*` flags.** Rejected: undocumented, and the
  failure mode is silent single-threaded builds — exactly what bit the prior iteration.
- **Standardize on the Makefile, drop CMake.** Rejected: CMake/ctest is the gate the
  agent workflow uses; it must be correct, not bypassed.

## Evidence
- `otool -L` before: no libomp in `build-macos-arm/k3`; after: libomp.dylib linked.
- Thread sweep before: flat at ~10 GFLOP/s; after: near-linear to 16 threads.
- `bin/k3` (Makefile) links `/opt/homebrew/opt/libomp/lib/libomp.dylib` and shows
  `__kmpc_*` symbols — the working reference this ADR brings CMake in line with.
