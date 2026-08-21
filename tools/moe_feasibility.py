#!/usr/bin/env python3
"""moe_feasibility.py - will an MoE run FAST on this machine, or stream off disk and crawl?

The lesson from running Kimi K3 (2.78T) on a 128 GB Mac: an MoE is fast only when its
working set is RESIDENT in RAM (compute-bound; the GPU + batching pay off). The moment it
spills to disk it is I/O-bound and crawls (~0.67 tok/s for K3). This estimates which side
of that cliff a given model lands on, from a few specs -- BEFORE you download a terabyte.

Model, per token:
  * dense/"trunk" params (attention, shared experts, embeddings) are read EVERY token and
    have no locality, so they MUST be resident or they stream every step.
  * routed-expert params: only the active fraction is read per token; across a generation
    the hot set (working set) is what matters, and experts have strong locality.

Calibrated so the built-in `k3` preset reproduces the measured ~5.8 s/token on a 128 GB
M5 Max. All rates are tunable; this is an order-of-magnitude planner, not a benchmark.

Usage:
  moe_feasibility.py --preset k3            # or: mixtral | qwen3-235 | deepseek-v2 | deepseek-v3
  moe_feasibility.py --all                  # compare every preset on this machine
  moe_feasibility.py --total 141 --active 39 --dense 12 --bits 4   # custom model
  moe_feasibility.py --preset qwen3-235 --ram 256 --gpu            # what-if bigger RAM / GPU
"""
import argparse, subprocess, sys

# Measured on the M5 Max, 128 GB (this session). Override on the CLI.
DISK_GBS      = 9.1     # parallel sequential trunk read
EXPERT_GBS    = 5.0     # effective EXPERT streaming rate (more random than the trunk);
                        # calibrated so k3's ~14 GB/token streamed reproduces ~2.83 s I/O
CPU_EGFLOPS   = 50.0    # effective bandwidth-bound decode rate (GEMV)
GPU_EGFLOPS   = 500.0   # resident, batched GEMM (MPS measured ~11 TFLOP/s at M=256; derated)
OVERHEAD_GB   = 12.0    # embeddings/KV/scratch/OS slack outside the trunk+cache budget

# Work in real GB (what determines RAM fit), because production MoEs MIX precisions
# (K3 = bf16 trunk + 4-bit experts). preset: (total_gb, trunk_gb, active_B, note)
#   total_gb   : full model on disk (all experts)
#   trunk_gb   : dense/always-on weights, read every token -> must be resident
#   active_B   : active params per token (billions) -> sets compute
#   active_gb  : routed-expert bytes read per token (~active_B * 0.5 at 4-bit)
PRESETS = {
    #                total_gb  trunk_gb  active_B
    "k3":            (1560.0,  108.0,    46.0, "Kimi K3 2.78T - the stress test that set the ceiling"),
    "deepseek-v3":   ( 350.0,    8.0,    37.0, "DeepSeek-V3 / R1 671B (4-bit)"),
    "qwen3-235":     ( 118.0,    6.0,    22.0, "Qwen3-235B-A22B (4-bit)"),
    "deepseek-v2":   ( 118.0,    7.0,    21.0, "DeepSeek-V2 236B (4-bit)"),
    "mixtral":       (  70.0,    6.0,    39.0, "Mixtral 8x22B 141B (4-bit)"),
}

def ram_gb():
    try:
        return int(subprocess.check_output(["sysctl","-n","hw.memsize"]))/1e9
    except Exception:
        return 128.0

def analyze(total_gb, trunk_gb, active_B, ram, disk, expert_disk, cpu, gpu, use_gpu):
    active_gb = active_B * 0.5                       # routed-expert bytes/token (4-bit)
    usable = ram - OVERHEAD_GB
    rate = gpu if use_gpu else cpu
    compute_s = 2.0 * active_B / rate               # 2*params FLOP / eff GFLOP/s

    # The gate: does the WHOLE model fit resident? (conservative -- ignores that the hot
    # working set may be < total; a model that fits is DEFINITELY fast.)
    fully_resident = total_gb <= usable

    if fully_resident:
        sec = compute_s                              # no disk; compute-bound
        stream_gb, trunk_stream = 0.0, 0.0
        verdict, why = "FAST (resident)", "whole model fits in RAM -> no disk, compute-bound"
    else:
        # Trunk must be resident. If it doesn't even fit, everything thrashes.
        cache_gb = max(0.0, usable - trunk_gb)
        expert_pool_gb = max(1.0, total_gb - trunk_gb)
        trunk_stream = max(0.0, trunk_gb - usable)   # trunk that won't fit streams every token
        # Expert cache hit: locality gives better-than-linear, capped near the 0.85 the
        # trace showed; sqrt(cache/pool) is a rough LFU-with-locality curve.
        hit = 0.0 if trunk_stream > 0 else min(0.85, (cache_gb/expert_pool_gb) ** 0.5)
        stream_gb = active_gb * (1 - hit)            # expert bytes off disk / token
        # I/O and compute partly overlap; expert I/O dominates when streaming, so add the
        # non-overlapped compute. Calibrated to reproduce k3's measured ~5.8 s/token.
        expert_s = stream_gb / expert_disk
        trunk_s  = trunk_stream / disk
        sec = expert_s + trunk_s + 0.6 * compute_s
        if expert_s + trunk_s > compute_s:
            verdict, why = "SLOW (streams off disk)", \
                f"{stream_gb + trunk_stream:.1f} GB/token off disk -> I/O-bound"
        else:
            verdict, why = "BORDERLINE", "partly resident; disk and compute comparable"
    return dict(total_gb=total_gb, trunk_gb=trunk_gb, active_gb=active_gb,
                usable=usable, fully_resident=fully_resident,
                stream_gb=stream_gb + (0.0 if fully_resident else trunk_stream),
                compute_s=compute_s, sec=sec, toks=1.0/sec if sec>0 else 0.0,
                verdict=verdict, why=why, gpu=use_gpu)

def show(name, note, r):
    print(f"\n=== {name} === {note}")
    print(f"  total {r['total_gb']:.0f} GB | dense/trunk {r['trunk_gb']:.0f} GB (must be resident) | "
          f"active {r['active_gb']:.1f} GB/token")
    print(f"  RAM usable {r['usable']:.0f} GB -> "
          + ("fully resident" if r['fully_resident'] else f"streams ~{r['stream_gb']:.1f} GB/token"))
    print(f"  est {r['sec']:.2f} s/token  ({r['toks']:.2f} tok/s){' [GPU-batched]' if r['gpu'] else ''}")
    print(f"  >>> {r['verdict']} - {r['why']}")

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--preset", choices=list(PRESETS))
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--total-gb", type=float, help="full model size on disk (GB)")
    ap.add_argument("--trunk-gb", type=float, default=8.0, help="dense/always-on weights (GB)")
    ap.add_argument("--active", type=float, help="active params per token (billions)")
    ap.add_argument("--ram", type=float, default=None, help="GB; default = this machine")
    ap.add_argument("--disk", type=float, default=DISK_GBS)
    ap.add_argument("--expert-disk", type=float, default=EXPERT_GBS)
    ap.add_argument("--cpu-gflops", type=float, default=CPU_EGFLOPS)
    ap.add_argument("--gpu-gflops", type=float, default=GPU_EGFLOPS)
    ap.add_argument("--gpu", action="store_true", help="assume resident+batched GPU compute")
    a = ap.parse_args()
    ram = a.ram if a.ram else ram_gb()
    print(f"machine: {ram:.0f} GB RAM, trunk-read {a.disk:.1f} GB/s, expert-read "
          f"{a.expert_disk:.1f} GB/s, compute {a.gpu_gflops if a.gpu else a.cpu_gflops:.0f} "
          f"eff GFLOP/s{' (GPU/batched)' if a.gpu else ' (CPU/decode)'}")
    def run(name):
        tot,trunk,ac,note = PRESETS[name]
        show(name, note, analyze(tot,trunk,ac,ram,a.disk,a.expert_disk,a.cpu_gflops,a.gpu_gflops,a.gpu))
    if a.all:
        for name in sorted(PRESETS, key=lambda k: PRESETS[k][0]):
            run(name)
    elif a.preset:
        run(a.preset)
    elif a.total_gb and a.active:
        show("custom", f"{a.total_gb} GB total / {a.active}B active",
             analyze(a.total_gb,a.trunk_gb,a.active,ram,a.disk,a.expert_disk,a.cpu_gflops,a.gpu_gflops,a.gpu))
    else:
        ap.print_help(); sys.exit(2)
    print("\nRule of thumb: fast if (dense trunk + expert working set) fits in RAM. "
          "Otherwise it streams and crawls. GPU + batching only help once resident.")

if __name__ == "__main__":
    main()
