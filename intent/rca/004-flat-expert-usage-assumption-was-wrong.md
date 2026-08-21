# RCA-004: The "flat expert usage" assumption was wrong — experts have strong locality

**Status:** Resolved
**Created:** 2026-08-20

## Summary
ADR-007 concluded path-2 throughput is disk-bound at ~0.67 tok/s (~3.9x single-stream),
reasoning that each token needs ~13.6 GB of experts off a 1.5 TB checkpoint that cannot be
RAM-resident, and that caching is near-useless because the router uses experts uniformly.
A user challenged this ("shouldn't we load what we can into RAM and bind that to GPU?").
Measuring `tools/sim_cache.py` on the committed expert trace showed the premise was wrong:
**90% of expert requests are repeats**, the active working set is **~176 GB (not 1.45 TB)**,
and a 192 GB cache hits 90% → expert I/O drops from 13.4 to 2.09 s/token (10x).

## Root Cause
Reused a design-time property as a runtime one. "Trained for flat expert usage" (in the
engine's comments) is about load-balancing *across all inputs during training* so every
expert gets gradient. It does NOT imply that *one generation* touches experts uniformly —
in fact a single conversation reuses a biased subset heavily (six experts fired on all 68
tokens of the trace). The disk-ceiling arithmetic inherited this false assumption and was
never checked against the trace tooling that already ships in the repo.

## Violated Requirement
The session's own standing rule — MEASURE before concluding (the rule that killed the
matmul-NEON and single-stream-GPU investments). ADR-007's ceiling was asserted from an
assumption, not measured, when `sim_cache.py` + `tests/fixtures/expert_trace.bin` were one
command away.

## Resolution
- ADR-007 corrected with the locality data and the real architecture: hold trunk (108 GB)
  + expert working set (~176 GB) resident (~285 GB total) and run GPU on it → compute-bound
  token → GPU/batching becomes the real lever. Needs a ~384 GB+ machine to fully realize.
- On 128 GB: partial (a ~128 GB cache is 49% LRU hit; BELADY shows 85% achievable, so a
  better cache policy is a real optimization — a new candidate story).
- Standing correction: re-evaluate the auto-sizer's "trunk worth ~70x expert cache"
  heuristic (same flat-usage origin) against the working-set threshold.

## Assumptions
| ID | Assumption | Basis | Status |
|----|-----------|-------|--------|
| A-1 | 90% locality generalises beyond this one 68-token trace | single committed trace; strong signal but one prompt | To confirm — dump traces from varied prompts (--dump-cache-trace) |
| A-2 | Working set ~176 GB is stable across prompts | trace: 12.14% of pool touched | To confirm on more traces |
| A-3 | A better-than-LRU policy can approach BELADY's 85% at 128 GB | sim shows the gap; policy not yet built | Open — candidate optimization |
