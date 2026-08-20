# ADR-006: GPU (Metal/MPS) is not worth a port for this workload

## Status
Accepted (spike outcome — closes the "GPU acceleration" investigation as NO-GO)

## Context
The user asked to explore GPU acceleration ("including using gpu"), sequenced after the
macOS autotune feature, and agreed to a **measurement spike before committing to a port**.
The spike (`spike/mps_matmul.mm`, `spike/metal_probe.mm`) ran on the M5 Max.

Toolchain reality first: `xcrun --find metal` fails — only Command Line Tools are
installed, not full Xcode — so **custom `.metal` shaders cannot be compiled**. MPS
(MetalPerformanceShaders) works (precompiled kernels), but MPS covers dense fp16/fp32
GEMM only. The routed experts — the dominant compute — are **MXFP4 (4-bit)**, which MPS
cannot consume; dequantising them on-GPU needs custom shaders, i.e. full Xcode.

Measured, on the real bf16 trunk matmul shape (12288 x 7168), single-token GEMV:

| path | ms | GFLOP/s | vs engine CPU |
|------|---:|--------:|--------------:|
| GPU (MPS, fp32, unified memory) | 1.31 | 134 | — |
| engine CPU (bench_kernels, 16 threads, tuned) | 1.92 | 114 | GPU ~1.2x |
| naive CPU in-spike (bf16->fp32 inline) | 3.79 | 46 | (not representative) |

Bit-exactness: **633 / 12288 outputs identical, max relative diff 1.35e-3.** GPU FP is
nowhere near the CPU reference — MPS accumulates in fp32 with its own reduction order,
the engine accumulates in double. This breaks the exact-token oracle (ADR-001).

## Decision
**Do not port the engine to GPU.** Five independent reasons, all measured or structural:
1. **~1.2x, not the hoped 2-10x.** The per-token matmul is a GEMV — bandwidth-bound, each
   weight read once — and the unified-memory CPU already saturates most of that bandwidth
   with 16 threads. The GPU's edge is small and partly eaten by reading fp32 (2x the bytes
   of bf16) and command-buffer overhead.
2. **The matmul is ~1 s of a ~5.8 s token.** Even a generous 2x on it saves ~0.5 s.
3. **The token is I/O-bound.** ~2.83 s/token is streaming MXFP4 experts from disk; the GPU
   cannot touch that floor. End-to-end ceiling with a perfect GPU is ~max(2.83, compute),
   i.e. ~3-4 s — a modest gain for a huge port.
4. **Bit-exactness breaks** (1.35e-3 rel). GPU means a new tolerance-based correctness
   regime, forking the engine's defining byte-identical guarantee.
5. **The dominant compute (MXFP4 experts) needs custom shaders → full Xcode**, which is not
   installed and is a heavier dependency than the whole project currently has.

## Consequences
- The GPU track closes here. The spike (~150 lines, one afternoon) saved a multi-week
  Metal port that would have delivered a modest, I/O-capped, non-bit-exact result.
- `spike/` is kept as the reproducible evidence. It does not build with the engine.
- The remaining material lever is the **persistent engine** (removes the ~22 s per-request
  trunk-pin — a latency/time-to-first-token win), not steady-state compute.

## Alternatives considered
- **Full Metal port (custom shaders).** Rejected: needs full Xcode; only helps the ~1 s
  matmul; breaks bit-exactness; capped by the 2.83 s I/O floor.
- **Hybrid: GPU for the bf16 trunk matmuls only, CPU for experts.** Rejected: the trunk
  matmuls are the *smaller* compute term, GPU gives ~1.2x on them, and CPU<->GPU handoff
  per layer adds latency. Net ~nil.
- **Wait for a bigger GPU / more bandwidth.** Out of scope; the I/O floor still dominates.

## Evidence
`spike/mps_matmul.mm` (numbers above), `spike/metal_probe.mm` (toolchain: M5 Max, unified
memory, 86.6 GB max buffer, MPS constructs under CLT). FINDINGS.md §3b/§3c for the
per-token budget and the I/O floor this conclusion rests on.
