# RCA-001: `-ffast-math` introduced into a bit-exact engine

**Status:** Resolved
**Created:** 2026-08-20
**Shape:** ACH-structured (competing hypotheses inline; incident is clear-cut
enough not to warrant the full 4-file bundle, but the reasoning is recorded per
nudge-4).

## Summary
The first NEON build iteration added `-march=armv8-a+fp16+dotprod -ffast-math` to
the arm64 branch of `CMakeLists.txt`. `-ffast-math` implies
`-funsafe-math-optimizations` (FP reassociation, contraction, no-signed-zeros),
which reorders reductions and is the most reliable single way to break the engine's
byte-identical-output guarantee. The 13-layer oracle still passed, so the defect was
not caught by the gate — a false sense of safety, because that toy model cannot
surface cross-layer argmax drift on the full 93-layer model.

## Analytic question
Why was a bit-exactness-breaking compiler flag introduced into a codebase whose
defining, README-headline property is byte-identical output across machines?

## Competing hypotheses
- **H1 (mundane — most likely): template reflex.** `-ffast-math` is a near-universal
  "make the ARM/SIMD build fast" boilerplate flag; it was added by pattern, without
  tracing it against constraint C-2. *Supporting:* it landed together with the arch
  flags in a single line, as a unit. *Counter:* none material.
- **H2: deliberate speed-over-exactness.** The author judged the speed worth the
  precision loss. *Supporting:* the sprint's north star is a speed target (≤5.6 s/tok).
  *Counter:* no ADR records such a trade; C-2 is marked `must`; the actual NEON code
  written (RMSNorm) went out of its way to *preserve* scalar order (double accumulate),
  which is the opposite of a speed-over-exactness posture. This internal inconsistency
  argues against a deliberate global choice.
- **H3: spec-sanctioned.** C-6 permits "≤1 ulp" per-kernel drift, which the author read
  as license for approximate math. *Supporting:* C-6 as written does allow non-exact
  output. *Counter:* `-ffast-math` is unbounded, not ≤1 ulp; and C-2 (same doc) demands
  frozen order. So the spec is contradictory, not permissive.

## Root Cause
Two compounding causes: (1) **a spec contradiction** — C-2 (bit-exact, frozen order)
vs C-6 (≤1 ulp) were both `must` and never reconciled, leaving "how exact is exact"
undefined; and (2) **template-reflex adoption** of `-ffast-math` (H1) into that
ambiguity, with no ADR forcing the trade-off to be examined. The oracle's tiny size
let it pass, hiding the defect.

## Violated Requirement
- **C-2** ("floating-point reduction order is *frozen* … byte-identical bit-exact
  output"). Directly breached by `-ffast-math`.
- The engine's implicit invariant: the full-model oracle (GATE 1–3) is exact-token, so
  any per-kernel latitude composes into gate failure at scale.

## Resolution
- **ADR-001** written: NEON kernels held to **bit-exact (0 ulp)**, not ≤1 ulp; C-6
  amended; reduction order frozen (f64 accumulation in scalar order, mirroring the
  AVX2 `__m256d` pattern).
- `-ffast-math` **removed** from the NEON build; `-ffp-contract=off` retained.
- Rebuilt; all 10 gates pass including the oracle.
- New standing requirement (ADR-001 §4): every SIMD-kernel change ships a per-kernel
  0-ulp fixture **and** a full-model token-diff, because the toy oracle alone cannot
  catch cross-layer drift.

## Assumptions
| ID | Assumption | Basis | Status |
|----|-----------|-------|--------|
| A-1 | Bit-exact NEON matmul is achievable for these kernels | AVX2 path is documented bit-identical via `__m256d`; NEON has f64 lanes | Held — proven for RMSNorm this iteration |
| A-2 | The oracle passing ≠ full-model correct | 13-layer/128-hidden vs 93-layer/7168-hidden; argmax is discontinuous | Held — motivates the token-diff requirement |
| A-3 | The precision cost of frozen order is off the critical path | dominant cost is memory streaming + matmul inner loop, both vectorizable bit-exactly | To be confirmed when the matmul kernel lands |
