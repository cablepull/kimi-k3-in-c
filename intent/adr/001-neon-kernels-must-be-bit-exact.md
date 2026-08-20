# ADR-001: NEON kernels must be bit-exact to the scalar path (not ≤1 ulp)

## Status
Accepted

## Context
Cites C-2 ("no functional regression … byte-identical bit-exact output for every
kernel that has reference fixtures. Floating-point reduction order is *frozen*") and
C-6 ("every SIMD kernel gets a fixture test, scalar ↔ neon diff ≤1 ulp on all
outputs").

**C-2 and C-6 contradict each other.** C-2 demands a *frozen reduction order* and
*byte-identical* output; C-6 permits a *≤1 ulp* per-output difference. These are not
the same tolerance, and the difference is load-bearing here:

- The engine's correctness gate is not a per-kernel tolerance — it is the full-model
  **oracle** (`tests/unit/k3_model.c`, GATE 1–3), which requires **exact token match**
  against a PyTorch reference. Greedy decode takes `argmax` over the logits; a
  sub-ulp perturbation that changes the argmax at a single position changes the token,
  and every downstream token with it.
- The released engine already achieves SIMD/scalar bit-exactness deliberately: the
  AVX2 path in `src/core/k3_ops.c` accumulates in `__m256d` and is documented as
  "BIT-IDENTICAL TO THE SCALAR PATH, not merely close," precisely so this gate holds
  across machines. The README's headline property is byte-identical output from the
  smallest machine to the largest.
- A ≤1 ulp allowance per kernel is not safe under composition: 93 layers × several
  matmuls, each free to differ by a ulp, drifts unboundedly relative to the reference
  and will eventually flip an argmax. The 13-layer/128-hidden oracle can pass while
  the full 93-layer/7168-hidden model diverges.

The prior iteration also added `-ffast-math` to the NEON build
(`CMakeLists.txt`), which enables `-funsafe-math-optimizations` (reassociation,
contraction, no-signed-zeros) — a direct violation of C-2's "frozen reduction order,"
and inconsistent with the `-ffp-contract=off` the same file sets for x86.

## Decision
1. **NEON kernels are held to bit-exactness with the scalar path, not ≤1 ulp.** C-6 is
   amended: the per-kernel fixture test asserts **0-ulp / bit-identical** outputs, the
   same bar the AVX2 path already meets.
2. **Reduction order is frozen.** A NEON reduction must reproduce the scalar summation
   tree — accumulate in `double` (f64) lanes and combine in the scalar order, exactly
   as the AVX2 path uses `__m256d`. Horizontal `vaddvq` over an f32 vector (which sums
   in a different order) is not permitted on any accumulation feeding logits.
3. **`-ffast-math` is removed** from the NEON build. `-ffp-contract=off` remains.
4. **Every SIMD kernel PR ships two tests:** the per-kernel bit-exact fixture (C-6, now
   0-ulp) *and* a full-model token-diff against a known-good capture, because the
   per-kernel test alone cannot catch cross-layer argmax drift.

## Consequences
- Wins: the engine keeps its defining guarantee (byte-identical output); the oracle
  gate stays meaningful; a passing macOS build is trustworthy, not "close."
- Costs: some NEON idioms are off-limits (fast horizontal reductions, FMA
  contraction), so a few kernels give up a little theoretical throughput to preserve
  order. This is the same trade the AVX2 path already made and is not on the critical
  path — the dominant cost is memory streaming and the matmul inner loop, both of
  which vectorize bit-exactly with f64 accumulation.

## Alternatives considered
- **Keep ≤1 ulp (C-6 as written).** Rejected: composes to argmax drift across 93
  layers; makes the oracle gate unfalsifiable as a correctness check; contradicts the
  engine's cross-machine reproducibility guarantee.
- **Keep `-ffast-math` for speed.** Rejected: it is the single most reliable way to
  break bit-exactness, and the reproducibility guarantee is worth more than the few
  percent it might buy in non-hot code.

## Evidence
- `src/core/k3_ops.c`: AVX2 paths documented bit-identical via `__m256d` accumulation —
  existence proof that bit-exact SIMD is achievable for these kernels.
- `tests/unit/k3_model.c` GATE 1–3: exact-token oracle; the gate this ADR protects.
- Measured: the existing NEON RMSNorm (this branch) already accumulates squares in a
  scalar `double` in scalar order and passes the oracle — the pattern this ADR mandates.
