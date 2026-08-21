# Loop prompt — Path 2: batched GPU throughput server for Kimi K3

Pass the block below to `/loop` (self-paced, no interval). It is a standing per-iteration
instruction: each firing advances the build by ONE small, verified step under the
magnetfragnet discipline, then stops until the next iteration.

Branch: `gpu-batched-server`. Goal recorded in ADR-006 (the batched-throughput opportunity)
and the S-P2-* stories in `intent.md`.

---

## THE LOOP PROMPT (copy from here)

You are building **Path 2**: turning the single-stream Kimi K3 CPU engine into a
**batched GPU inference server** on Apple Silicon, where the GPU accelerates the GEMM that
appears when many tokens/requests are processed together. Authority: ADR-006 measured GPU
at 10–200× for GEMM (M≥16) while it is ~parity for single-token decode. This is a different
*product* from the single-stream engine and a large build; make progress in small, verified
steps.

Work on branch `gpu-batched-server`. Do exactly ONE iteration per firing:

1. **Orient (cheap).** Read `intent.md` (constraints C-*, stories S-P2-*), the latest
   `intent/adr/*` and `intent/rca/*`, and `git log --oneline -8`. Run
   `magnetfragnet eval` to see cross-iteration signals (stuck primary, overdue audit).
   Pick the single highest-value *next* story or sub-task — the smallest thing that moves
   the goal and can be verified this iteration.

2. **Guardrails (non-negotiable — learned the hard way, see RCA-001..003).**
   - NEVER run a config that risks OOM. Size memory only via `bin/k3 ... --dry-run`
     (allocates nothing). The engine already reboots the machine if pushed past RAM.
   - MEASURE before you optimize. Prove a speedup in an isolated microbenchmark
     (`bench_kernels`-style, with a bit-exactness/tolerance hash) before wiring it in.
     Single full-model runs have a ~5–7% noise floor; don't over-read one delta.
   - The GPU path abandons bit-exactness by design (GPU FP ≠ CPU reference). That is an
     explicit correctness-regime change — it MUST be governed by an ADR (see step 5) and a
     tolerance-based validation harness, never a silent slide. The CPU single-stream path
     must stay byte-identical and its oracle must keep passing.
   - Two hard prerequisites, check them before depending on them: the MXFP4 expert kernels
     need custom Metal shaders → **full Xcode** (`xcrun --find metal`). If it is absent,
     do not fake progress: record the blocker, do the MPS-only (bf16 trunk) work that
     needs no shader compiler, and surface "needs `xcode-select`/Xcode install" to the user.

3. **Implement one step (TDD where it fits).** Red → green → refactor. Keep the CPU engine
   building and `make test` green throughout. GPU code is Objective-C++ (`.mm`) under
   `spike/` or a new `src/gpu/`, linked against Metal/MPS frameworks (no shader compiler
   needed for MPS; custom shaders need Xcode). Prefer MPS for dense GEMM; reserve custom
   shaders for MXFP4 dequant.

4. **Record the iteration in magnetfragnet.** After the change:
   `magnetfragnet check --files <each changed file> --loc-added N --loc-removed M --verbose`.
   Read the returned primary nudge and `all_fired`.

5. **Address the nudge / keep the discipline.**
   - Architecture decision (new module, the correctness-regime change, batching scheduler
     design, a build-system change) → write an ADR under `intent/adr/NNN-*.md` (immutable,
     cite C-*/prior ADRs).
   - A surprise, a fix that turned out to be a workaround, a repeated failure, or an
     incident → write an RCA under `intent/rca/`.
   - If nudge-9 (architecture-audit) is primary AND you have real evidence to stress-test,
     produce the ACH audit bundle under `intent/audits/<id>/` and call
     `magnetfragnet audit_completed`; otherwise note it deferred with a reason.
   - Do not chase a nudge in circles (`eval-stuck-primary` guards this).

6. **Commit** with a clear message (what + why), Co-Authored-By trailer. Update
   `FINDINGS.md` / `docs/MACOS.md` if a user-visible fact changed. Do NOT merge to `main`
   or push without the user's say-so unless a story explicitly authorizes it.

7. **Report & stop.** In 3–6 lines: what this iteration did, the measured result (or the
   blocker), the magnetfragnet primary nudge, and the single next step. Then end the
   iteration — do not start the next task.

**Definition of done for the loop:** a working batched server that (a) accepts concurrent
requests, (b) dynamically batches their decode steps, (c) runs the batched GEMM on the GPU,
(d) is validated against the CPU reference within a documented tolerance, and (e) shows a
measured tokens/sec throughput win over N single-stream CPU instances at batch ≥ 16.

**Stop the loop and ask the user** if: a hard prerequisite is missing (Xcode), a decision
needs product input (how much accuracy to trade for throughput), the approach isn't
converging after ~3 iterations on the same sub-task, or the token budget for the session is
running low.

---

## Seed backlog (also mirrored as S-P2-* in intent.md)

- **S-P2-1** ADR: batched-server architecture + the tolerance-based correctness regime.
- **S-P2-2** Prereq gate: detect Xcode/metal compiler; MPS-only vs full-shader plan.
- **S-P2-3** Batched decode harness: run M token-streams through the decoder together.
- **S-P2-4** GPU bf16 trunk GEMM via MPS, resident (unified-memory) weights, tolerance test.
- **S-P2-5** MXFP4 expert dequant + GEMM as a custom Metal shader (needs Xcode).
- **S-P2-6** Dynamic request batching / scheduler (merge concurrent decode steps).
- **S-P2-7** Tolerance validation harness (replaces the exact-token oracle for the GPU path).
- **S-P2-8** Throughput benchmark: tokens/sec vs batch size vs CPU single-stream baseline.
