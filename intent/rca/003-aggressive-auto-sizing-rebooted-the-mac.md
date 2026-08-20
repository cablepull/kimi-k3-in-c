# RCA-003: Aggressive auto-sizing drove a 128 GiB Mac into a reboot

**Status:** Resolved
**Created:** 2026-08-20

## Summary
While adding macOS support to `--preset auto`, the RSS ceiling was set to
`available - 4 GB`. On a fresh boot Darwin reported ~123 GB "available" (it counts
reclaimable cache/purgeable pages), so auto sized the trunk to ~95+ GB. With the OS,
window server, the Python shim, and other apps also resident, the working set exceeded
physical RAM, the machine swap-stormed, and it rebooted — losing the user's session.

## Root Cause
Two compounding errors:
1. **Trusting Darwin's "available."** macOS reports reclaimable memory as available, but
   that memory cannot all be handed back instantly under a sudden ~95 GB allocation.
   Sizing to it overcommits.
2. **No dry-run.** The only way to check a sizing decision was to actually run it, i.e.
   to allocate ~95 GB — the very act that was unsafe. There was no way to inspect a
   config without risking the machine.

Contributing: an earlier `--trunk-gb 100` sweep point had already shown the machine swaps
at ~111 GB RSS (81% of the 137 GB the kernel reports), but that empirical swap point was
not fed back into the auto ceiling.

## Violated Requirement
- The user's directive that resource use "must remain tunable" implies it must also be
  SAFE by default — an unattended auto config must never crash the host.
- Implicit: a tool that maximizes a resource must not be able to exhaust it.

## Resolution (all committed)
- **Conservative ceiling.** macOS auto now keys off TOTAL RAM minus ~28% headroom
  (min 20 GB), not "available". On 128 GiB it picks trunk-gb ~77 → ~84 GB peak, ~54 GB
  clear. Speed is flat across that range, so safety costs ~nothing.
- **`--dry-run`.** Resolves and prints the memory plan, then exits before allocating a
  single byte. Sizing can now be checked with zero risk.
- **Empirical swap warning.** The dry-run flags a plan whose est. peak RSS exceeds 78%
  of RAM ("tight") or 85% ("OVER SAFE RAM"), based on the observed ~81% swap point — not
  at 100%, which would call a machine-killer "fine".
- **`--headroom-gb N`** tunable, floored at 8 GB, for dedicated machines — kept honest by
  the same warning.
- **`k3-autotune.sh`** wraps all of this via `--dry-run` and REFUSES to recommend a config
  the warning flags. It cannot push the machine into swap.

## Assumptions
| ID | Assumption | Basis | Status |
|----|-----------|-------|--------|
| A-1 | The ~81% swap point generalises | one reboot + one swap at ~111 GB / 137 GB | Held provisionally; the 28% default keeps well clear |
| A-2 | Speed is flat 77–95 GB trunk | sweep: 90 vs 95 tied within noise | Held (FINDINGS §3c) |
| A-3 | est. peak RSS = trunk+cache+~6.4 GB | matches measured gap on this machine | Held; used only for the warning, real RSS still printed after a run |
