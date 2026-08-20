# ADR-005: macOS auto-tuning is safe by default, tunable on demand

## Status
Accepted

## Context
Cites the user directive: "All matters dependent on system resource must remain tunable,
and it would be nice to have a tool to maximize it," and RCA-003 (aggressive auto-sizing
rebooted the host). The engine already had `--trunk-gb`/`--cache-gb`/`--preset auto`, but
`--preset auto` read `/proc/meminfo` and so failed on every Mac, and a first macOS port of
it overcommitted RAM and rebooted the machine. Not every Mac is a 128 GB M-series; the
feature has to work — and stay safe — from an 8 GB laptop upward.

## Decision
1. **`--preset auto` works on macOS** via Mach VM statistics (`host_statistics64`) for
   available and `sysctl hw.memsize` for total, mirroring the k3-doctor port.
2. **Safe by default, not maximal by default.** macOS auto keys off TOTAL RAM minus a
   generous headroom (~28%, min 20 GB), never off Darwin's generously-reported
   "available". The default leaves the OS and other apps ample room; an unattended run
   cannot crash the host.
3. **Tunable:** `--headroom-gb N` (floor 8 GB) lets a dedicated machine pin closer to the
   metal; explicit `--trunk-gb`/`--cache-gb` still override everything.
4. **`--dry-run`** resolves and prints the memory plan (trunk, cache, est. peak RSS,
   headroom, swap warning) and exits before allocating anything — the only safe way to
   inspect a ~100 GB config.
5. **`scripts/k3-autotune.sh`** is the maximizer tool: it sizes via `--dry-run`, recommends
   a thread count (N-2 on Apple Silicon for P/E-core contention), prints the exact command,
   and REFUSES any plan the swap warning flags.

## Consequences
- Works on any Mac; sizes conservatively; the maximizer cannot exhaust RAM.
- The safe default (~77 GB trunk on 128 GiB) is slightly below the empirical optimum
  (~95 GB), but speed is flat across that range (FINDINGS §3c), so the cost is ~noise while
  the safety margin triples (~54 GB clear vs ~20 GB).
- New standing rule: any future resource-sizing feature ships a `--dry-run` path and an
  empirical (not 100%-of-RAM) safety threshold.

## Alternatives considered
- **Maximal by default, trusting "available."** Rejected — it rebooted the machine
  (RCA-003). "Available" on Darwin includes reclaimable cache and overcommits.
- **Empirical autotune that runs candidate configs and backs off.** Deferred — even a
  backing-off run must first allocate near the ceiling to discover it; `--dry-run` +
  the total-RAM model gets a safe answer without ever risking swap. An opt-in
  `--measure` mode can be added later once the dry-run model is trusted.

## Evidence
- `--preset auto --dry-run` on 128 GiB: trunk 76.8 / peak 83.7 / 53.8 GB clear.
- `--headroom-gb 2 --dry-run`: peak 118 GB → "OVER SAFE RAM" → autotune refuses.
- Oracle exact after the arg-parsing changes; RCA-003 for the incident this prevents.
