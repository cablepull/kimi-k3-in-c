# GPU spike (metal-gpu branch)

Measurement spike to decide GO/NO-GO on a GPU/Metal port. **Outcome: NO-GO**
(see `intent/adr/006-gpu-metal-not-worth-a-port.md`).

- `metal_probe.mm` — confirms Metal + MPS work under Command Line Tools (no full Xcode).
- `mps_matmul.mm`  — MPS bf16 GEMV vs CPU: speed and bit-exactness delta.

Build (needs no metal shader compiler, only the frameworks):

    clang++ -std=c++17 -O3 -fobjc-arc -Xpreprocessor -fopenmp \
        -I/opt/homebrew/opt/libomp/include mps_matmul.mm -o mps_matmul \
        -L/opt/homebrew/opt/libomp/lib -lomp \
        -framework Metal -framework MetalPerformanceShaders -framework Foundation

Result on M5 Max: GPU ~1.2x the tuned 16-thread CPU matmul (bandwidth-bound GEMV),
and NOT bit-exact (max rel diff 1.35e-3). The token is I/O-bound anyway. Not worth a port for single-stream decode; but GPU is 10-200x for GEMM (prefill/batched serving) -- see ADR-006 crossover table.
