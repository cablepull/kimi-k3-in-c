# Research note 001 — Expert cache policy (LFU vs LRU) and the 128 GB RAM wall

**Date:** 2026-08-20  **Branch:** expert-cache  **For:** S-10 (attack the expert-I/O floor)

## Question
Can a better expert-cache policy than LRU meaningfully cut the ~2.83 s/token expert I/O on
the 128 GB M5 Max? (Prompted by RCA-004: experts have strong locality — 90% reuse, ~176 GB
working set — so caching should help.)

## Method
`tools/sim_cache.py` + custom analysis over the committed 68-token expert trace
(`tests/fixtures/expert_trace.bin`): 100,096 accesses, 10,010 distinct experts.

## Finding 1 — LFU is a MUCH better policy than LRU (measured on the trace)
The access is a **cyclic scan over a working set larger than the cache** (each token walks
all 92 layers × 16 experts), the textbook case where LRU is pessimal — it evicts by recency
and thrashes the loop. Frequency (LFU) keeps the hot experts instead. Simulated hit rate:

| expert cache | LRU | **LFU** | LFU gain |
|-------------:|----:|--------:|---------:|
| 32 GB | 36% | 37% | +0 |
| 64 GB | 36% | 47% | +10 |
| 96 GB | 36% | 48% | +12 |
| **128 GB** | **49%** | **80%** | **+30 pts** |
| 160 GB | 76% | 89% | +13 |

LFU at a 128 GB cache reaches **80% hit** (near the 90% compulsory-miss ceiling) vs LRU's
49%. The policy win is real and large. The distribution is Zipfian: top 23% of experts =
50% of accesses; top 72% (126 GB) = 90%.

## Finding 2 — but on 128 GB the trunk eats the RAM, so the win is unreachable HERE
LFU only beats LRU once the cache exceeds ~64 GB (below that, LFU ≈ LRU ≈ 36%). And the
128 GB machine cannot afford a big expert cache, because the **trunk (108 GB) has NO
locality** — every token reads all of it — so it must be resident, or it streams at ~12
s/token. That leaves only ~2 GB for the expert cache, where LFU == LRU.

    LFU's 80% win needs:  trunk 108 GB + cache 126 GB  = ~234 GB resident
    GPU compute-bound token needs: trunk 108 + working set 176 = ~285 GB
    we have: 128 GB  -> can hold the trunk OR a useful cache, not both

So the expert-cache policy hits the **same RAM wall as the GPU** (ADR-006): both of the
promising levers need ~234-285 GB, and 128 GB is fundamentally too small to hold the trunk
*and* a useful fraction of the 176 GB expert working set at once.

## Finding 3 — quantizing the trunk doesn't rescue it
An int8 trunk (~54 GB, non-bit-exact) frees ~54 GB for the cache, but LFU at ~74 GB is only
~47% — still far below the ~80% that needs a 126 GB cache. Even aggressive quantization
does not reach the LFU sweet spot on 128 GB. Not worth the correctness cost.

## Conclusion
- **The LFU policy is worth implementing** — it is strictly better than LRU and is the
  right policy for any machine with a cache large enough to matter (≥64 GB expert cache).
- **It does not help on this 128 GB machine**, because the trunk consumes the RAM and the
  affordable cache (~2 GB) is below where LFU beats LRU. The current pin-trunk / tiny-cache
  config is near-optimal at 128 GB (the auto-sizer's "trunk ≫ expert cache at the margin"
  holds at small cache sizes).
- **Both of the user's instincts (GPU, better cache) are correct — and both are RAM-gated
  to ~234-285 GB.** On a 256-384 GB Mac Studio/Ultra, LFU cache + GPU + batching all pay
  off together and K3 becomes dramatically faster and high-throughput. On 128 GB, K3 is at
  its honest floor (~5.8 s/token).

## Recommendation
1. Implement LFU as a selectable cache policy anyway (small, bit-exact, no downside; unlocks
   the win the moment the cache is big enough — bigger-RAM box or the batched-server build).
2. Do NOT expect a 128 GB speedup from it — set that expectation before implementing.
3. The real decision is hardware target (see the decision this note feeds): accept the
   128 GB floor, or plan for a ≥256 GB machine where every lever (LFU, GPU, batching) lands.

## Gaps / to-confirm
- One trace (68 tokens, one prompt). Confirm the Zipfian skew and ~176 GB working set on
  varied real prompts (`--dump-cache-trace`) before trusting the exact numbers.
- LFU needs aging/decay to avoid stale-hot pollution across long sessions; simulate that.
