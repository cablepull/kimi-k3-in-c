# Research note 002 — MoE feasibility on Apple Silicon: the resident/streaming cliff

**Date:** 2026-08-21  **On:** main  **Tool:** `tools/moe_feasibility.py`

## The one thing that determines fast vs slow
Running Kimi K3 (2.78T) on a 128 GB M5 Max mapped the cliff every MoE lands on:

> An MoE is **fast** iff its working set is **resident in RAM** (compute-bound; the 40-core
> GPU + batching pay off). The moment it spills to disk it is **I/O-bound and crawls**
> (~0.19 tok/s for K3). Nothing software-side moves that — it is a RAM question.

## The budget
```
resident need = dense trunk (read EVERY token, no locality -> must be resident)
              + expert working set (hot experts; strong locality, but sized by the model)
fast if:  resident need  ≲  RAM − overhead
```
Measured anchors (this session): expert I/O ~2.83 s/token dominates the K3 token; disk does
~9 GB/s sequential / ~5 GB/s random-expert; CPU decode is bandwidth-bound (~parity with the
GPU at batch 1); the GPU is 10–200× only for batched GEMM (resident); LFU beats LRU 80% vs
49% but only once the cache is large enough to matter.

## Where real models land (from `moe_feasibility.py`, 128 GB Mac)
| model | 4-bit size | verdict | CPU s/tok | GPU-batched |
|-------|-----------:|---------|----------:|------------:|
| Mixtral 8x22B (141B) | 70 GB | **FAST — resident** | 1.6 | **6.4 tok/s** |
| DeepSeek-V2 (236B) | 118 GB | **FAST — resident** | 0.8 | **11.9 tok/s** |
| Qwen3-235B-A22B | 118 GB | **FAST — resident** | 0.9 | **11.4 tok/s** |
| DeepSeek-V3 / R1 (671B) | 350 GB | SLOW — streams | 2.4 | — |
| **Kimi K3 (2.78T)** | 1560 GB | **SLOW — streams** | 5.2¹ | — |

¹ tool says 5.2, we measured 5.8 — calibrated within its ±30% planning accuracy.

**The sweet spot on 128 GB is a ~100–236 B-param MoE in 4-bit** — it fits fully resident,
runs 0.8–1.6 s/token on CPU today, and **6–12 tok/s once GPU-batched** (usable for real
interactive/agent work, unlike K3). K3 isn't the product; it's the stress test that
calibrated where the product line is.

## Design levers (priority order) to keep a new MoE on the fast side
1. **Total (or working-set) size ≤ RAM.** The gate. A model that fits is definitely fast.
2. **Small dense trunk.** It's resident and has no locality, so it directly steals RAM from
   experts. Lean attention / few shared experts wins.
3. **4-bit (MXFP4) experts.** Halves the resident footprint — the fit/no-fit difference.
4. **LFU (not LRU) expert cache** for models whose working set is *slightly* over RAM —
   locality + a good policy bridges the gap (RCA-004, research-001).
5. **GPU-batch it once resident.** ADR-007's batched server is useless when streaming but
   the throughput rocket the moment the model fits.

## The tooling this session built to apply the framework
- `tools/moe_feasibility.py` — predicts fast/slow + est tok/s for any model from a few
  specs (size, trunk, active params), CPU or GPU-batched, at any RAM. Compare-all built in.
- `tools/sim_cache.py` + `--dump-cache-trace` — measure a model's real working set & hit
  curve before committing to a download.
- `scripts/k3-autotune.sh` + `--dry-run` — size it safely; `bench_kernels` + the GPU spike
  — the compute ceiling and where GPU pays.

## Bottom line
K3 taught the ceiling by exceeding it. The same engine + macOS port + autotune, pointed at
a right-sized (~100–236 B, 4-bit) MoE, is **fast and usable** on this M5 Max — and
`moe_feasibility.py` tells you, per model, which side of the cliff it's on before you
download a terabyte.

## Gaps
- Presets use published spec estimates; verify a candidate's real trunk/working-set with
  `--dump-cache-trace` before trusting exact tok/s.
- GPU tok/s assumes the batched-server (ADR-007) is built and the model is bit-tolerant.
