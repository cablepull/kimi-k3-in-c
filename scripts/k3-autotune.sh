#!/usr/bin/env bash
# k3-autotune, pick the fastest engine config THIS machine can run safely.
#
#   scripts/k3-autotune.sh <model_dir> <trunk_dir> [--headroom-gb N] [--run "PROMPT"]
#
# The engine already sizes itself with `--preset auto`; this wraps it to (1) show the
# plan, (2) let you trade safety headroom for speed with --headroom-gb, and (3) print
# the exact command to run. Sizing is checked with `--dry-run`, which allocates NOTHING,
# so autotune can never push the machine into swap -- the failure it exists to prevent.
#
# Speed is flat across a wide trunk-budget range (pinning 77 vs 95 GB is within noise on
# a 128 GB Mac), so the conservative default is the right default; --headroom-gb is for a
# dedicated machine that wants to pin closer to the metal.
set -euo pipefail

BIN="$(dirname "$0")/../bin/k3"
MODEL="${1:?usage: k3-autotune.sh <model_dir> <trunk_dir> [--headroom-gb N] [--run \"PROMPT\"]}"
TRUNK="${2:?need the packed trunk dir}"
shift 2

HEADROOM=""
RUN_PROMPT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --headroom-gb) HEADROOM="$2"; shift 2 ;;
        --run)         RUN_PROMPT="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -x "$BIN" ] || { echo "engine not built: $BIN (run make)"; exit 1; }

# Recommended thread count. On Apple Silicon the matmul peaks a couple of threads below
# the core count (P/E-core contention); elsewhere use all cores.
NCPU=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)
case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) THREADS=$(( NCPU > 2 ? NCPU - 2 : NCPU )) ;;
    *)            THREADS=$NCPU ;;
esac

HARG=()
[ -n "$HEADROOM" ] && HARG=(--headroom-gb "$HEADROOM")

echo "autotune: sizing (dry-run, nothing allocated)…"
# "${HARG[@]+...}" expands to nothing when the array is empty; a bare "${HARG[@]}"
# trips `set -u` ("unbound variable") on an empty array in bash.
PLAN=$("$BIN" "$MODEL" --trunk "$TRUNK" --preset auto --dry-run \
       "${HARG[@]+"${HARG[@]}"}" 2>&1)
echo "$PLAN"

# Refuse to recommend a config the dry-run flagged as over the safe RAM ceiling.
if echo "$PLAN" | grep -q "OVER SAFE RAM"; then
    echo
    echo "REFUSING: the requested headroom puts peak RSS over physical RAM. Raise"
    echo "--headroom-gb (or drop it for the safe default) and re-run." >&2
    exit 1
fi

# Anchor on the dry-run plan lines ("... : N GB"); the "auto budget:" line also mentions
# "expert cache" without a colon, so match the colon to avoid grabbing the wrong field.
TRUNK_GB=$(echo "$PLAN" | awk -F'[: ]+' '/trunk budget *:/{print $(NF-1)}')
CACHE_GB=$(echo "$PLAN" | awk -F'[: ]+' '/expert cache *:/{print $(NF-1)}')

echo
echo "recommended command for this machine:"
echo "  OMP_NUM_THREADS=$THREADS \\"
echo "  $BIN $MODEL --trunk $TRUNK \\"
echo "      --trunk-gb $TRUNK_GB --cache-gb $CACHE_GB --incremental \\"
echo "      --tok $MODEL --prompt \"…\" --gen N"
echo
echo "(steady-state is compute+I/O bound; more trunk pinning past this point is within"
echo " the noise floor. Pass --headroom-gb to pin closer to the metal on a dedicated box.)"

if [ -n "$RUN_PROMPT" ]; then
    echo
    echo "running the recommended config…"
    OMP_NUM_THREADS=$THREADS "$BIN" "$MODEL" --trunk "$TRUNK" \
        --trunk-gb "$TRUNK_GB" --cache-gb "$CACHE_GB" --incremental \
        --tok "$MODEL" --prompt "$RUN_PROMPT" --gen 16
fi
