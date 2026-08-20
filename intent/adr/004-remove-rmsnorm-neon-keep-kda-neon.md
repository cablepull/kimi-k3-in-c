# ADR-004: Remove the RMSNorm NEON; keep the KDA-step NEON (microbench-decided)

## Status
Accepted

## Context
Cites ADR-001 (bit-exact) and ADR-003 (SIMD only where it moves the measured token).
Two hand-written NEON kernels existed: RMSNorm (from the prior agent) and `k3_kda_step`
(this work). A full-model run appeared to regress when both were activated, but that run
was confounded — enabling `-DK3_ENABLE_ARM_NEON` (via the CFLAGS/CPPFLAGS fix) turned on
BOTH kernels at once, and single full runs carry ~5–7% run-to-run noise.

`bench_kernels` was extended with isolated RMSNorm and `k3_kda_step` micro-cases (each
prints an FNV1a of its output for a bit-exactness check), built once with the NEON define
and once without:

| kernel | scalar (compiler auto-vec) | hand NEON | FNV match | verdict |
|--------|---------------------------:|----------:|:---------:|---------|
| RMSNorm n=7168 | 3729 ns | 4248 ns | yes | NEON **14% slower** |
| RMSNorm n=16   | 3.5 ns  | 3.9 ns  | yes | NEON slower |
| `k3_kda_step` D=16 | 109.5 ns | 77.9 ns | yes | NEON **29% faster** |

## Decision
1. **Remove the RMSNorm NEON.** It is bit-identical but slower: its per-lane
   `vgetq_lane_f32` reductions serialise on ARM, and `-mcpu=native` already
   auto-vectorises the scalar loop. Keep scalar. Absolute cost either way is tiny
   (~0.1 ms/token across all n=7168 norms), so this is correctness/clarity, not speed.
2. **Keep the `k3_kda_step` NEON** (with the per-call `calloc` removed): 29% faster at
   the kernel, bit-exact (oracle GATE 3, which carries KDA state, passes 20/20). KDA is
   ~0.91 s/token, so ~0.26 s/token potential end-to-end.

## Consequences
- Net: one kernel deleted (regression), one kept (win). Both keep the engine bit-exact.
- **Honesty caveat:** the KDA end-to-end saving (~0.26 s of ~6 s) is ~4%, BELOW the
  ~5–7% single-run noise floor. The *microbench* (29%, isolated) is the reliable
  evidence; a single full run cannot confirm it. Any future full-run perf claim needs
  repeated runs or an effect above the noise floor. (Recorded in FINDINGS.md.)
- Method win: kernel micro-cases in `bench_kernels` are the right tool for SIMD
  decisions — seconds, isolated, with a built-in bit-exactness hash — not 5-minute
  full-model runs.

## Alternatives considered
- **Keep RMSNorm NEON.** Rejected: measured slower, no upside.
- **Trust the full-run regression and revert KDA too.** Rejected: the isolated microbench
  shows KDA NEON is a real 29% win; the full-run signal was the RMSNorm confound + noise.

## Evidence
`bench_kernels` rmsnorm/kda_step cases (scalar vs NEON builds); FNV1a hashes equal in
both; oracle GATE 3 exact with the final kernel set.
