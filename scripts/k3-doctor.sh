#!/usr/bin/env bash
# k3-doctor, check whether this machine can run Kimi K3, and how fast.
#
# Answers three questions before you spend an hour finding out the hard way:
#   1. Is the toolchain present and does the engine build?
#   2. How much memory is there, and which preset does that imply?
#   3. How fast is the storage the weights will stream from?
#
# Exits non-zero if the machine cannot run the model at all.
#
# Linux is the reference platform; macOS is supported. Everything Linux-specific here
# (/proc/meminfo, GNU dd/df, O_DIRECT) has a Darwin branch below: sysctl/vm_stat for
# memory, and an F_NOCACHE read probe for storage, which is how the engine itself
# reads on Darwin, so the measured rate is the one the engine will see.

set -u

OS=$(uname -s)
case "$OS" in
    Linux|Darwin) ;;
    *)  echo "k3-doctor: unsupported platform: $OS (Linux and macOS only)"
        exit 1 ;;
esac

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
[ -t 1 ] || { RED=""; GRN=""; YLW=""; DIM=""; RST=""; }

ok()   { printf '  %sok%s    %s\n'   "$GRN" "$RST" "$*"; }
warn() { printf '  %swarn%s  %s\n'   "$YLW" "$RST" "$*"; }
bad()  { printf '  %sFAIL%s  %s\n'   "$RED" "$RST" "$*"; FAILED=1; }
hdr()  { printf '\n%s\n' "$*"; }

FAILED=0
MODEL_DIR="${1:-}"

printf '%s\n' "Kimi K3, environment check"

# ------------------------------------------------------------------ toolchain --
hdr "toolchain"
if command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1; then
    CCBIN=$(command -v cc || command -v gcc)
    ok "C compiler: $($CCBIN --version 2>&1 | head -1)"
else
    bad "no C compiler found (install build-essential or equivalent)"
fi
command -v make >/dev/null 2>&1 && ok "make: $(make --version | head -1)" || bad "make not found"
if command -v python3 >/dev/null 2>&1; then
    ok "python3: $(python3 --version 2>&1)"
else
    warn "python3 not found, the trunk packer and reference tools need it"
fi
if [ "$OS" = Darwin ]; then
    # Apple Clang ships no OpenMP runtime, so on macOS libomp is a BUILD requirement,
    # not an optimization: the Makefile links it explicitly and `make` fails without it.
    if [ -e "$(brew --prefix libomp 2>/dev/null)/lib/libomp.dylib" ]; then
        ok "libomp: $(brew --prefix libomp)"
    else
        bad "libomp not found; the build needs it on macOS: brew install libomp"
    fi
fi

# ------------------------------------------------------------------------ cpu --
hdr "cpu"
NCPU=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
ok "cores: $NCPU"
ARCH=$(uname -m)
if [ "$ARCH" = arm64 ] || [ "$ARCH" = aarch64 ]; then
    # The engine's only hand-written SIMD path is AVX2; on arm64 it runs the scalar
    # path, auto-vectorized by the compiler under -mcpu=native. Correct output, and
    # decode is I/O-bound at the streaming presets anyway; the gap shows only where
    # the trunk is resident and decode turns compute-bound.
    ok "$ARCH ($(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown))"
    printf '  %sinfo  no AVX2 on arm64: the engine uses its scalar path, compiler-vectorized%s\n' "$DIM" "$RST"
else
    if [ "$OS" = Darwin ]; then HAS_AVX2=$(sysctl -n machdep.cpu.leaf7_features 2>/dev/null | grep -c AVX2)
    else HAS_AVX2=$(grep -cm1 avx2 /proc/cpuinfo 2>/dev/null); fi
    if [ "${HAS_AVX2:-0}" -ge 1 ]; then
        ok "AVX2: present"
    else
        warn "AVX2 not detected, the engine will run but the expert matmuls lose their fast path"
    fi
    if [ "$OS" = Darwin ]; then HAS_512=$(sysctl -n machdep.cpu.leaf7_features 2>/dev/null | grep -c AVX512F)
    else HAS_512=$(grep -cm1 avx512f /proc/cpuinfo 2>/dev/null); fi
    [ "${HAS_512:-0}" -ge 1 ] && ok "AVX-512: present" \
        || printf '  %sinfo  AVX-512 absent (not required)%s\n' "$DIM" "$RST"
fi

# --------------------------------------------------------------------- memory --
hdr "memory"
if [ "$OS" = Darwin ]; then
    MEM_GB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
    # Darwin has no MemAvailable. The closest honest figure is what the kernel can hand
    # out without swapping: free + inactive + speculative + purgeable pages. Compressed
    # memory makes this an estimate that reads LOW on a busy machine, which errs toward
    # recommending a smaller preset -- the safe direction.
    AVAIL_GB=$(vm_stat | awk -v ps="$(sysctl -n vm.pagesize)" '
        /Pages (free|inactive|speculative|purgeable)/ { gsub("\\.",""); n += $NF }
        END { printf "%d", n * ps / 1073741824 }')
else
    MEM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    MEM_GB=$(( MEM_KB / 1024 / 1024 ))
    AVAIL_KB=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
fi
ok "total: ${MEM_GB} GB, available: ${AVAIL_GB} GB"

# Boundaries follow the measured memory ladder (docs/PERFORMANCE.md). Expectations are v1.0.0
# anchors from docs/data/speed-2026-08.md on the reference box (124 cores, fast NVMe): treat
# them as order-of-magnitude, not a promise. Streaming presets (laptop/desktop/workstation)
# scale with your disk; the trunk becomes resident above ~128 GB, where decode is compute-bound
# and scales with core count instead.
if   [ "$AVAIL_GB" -ge 192 ]; then PRESET=server;      EXPECT="~6 s/token"
elif [ "$AVAIL_GB" -ge  96 ]; then PRESET=workstation; EXPECT="~6-20 s/token"
elif [ "$AVAIL_GB" -ge  32 ]; then PRESET=desktop;     EXPECT="~24 s/token"
elif [ "$AVAIL_GB" -ge  10 ]; then PRESET=laptop;      EXPECT="~27 s/token"
else PRESET=""; fi

if [ -n "$PRESET" ]; then
    ok "recommended preset: --preset $PRESET   (expect $EXPECT)"
else
    # A warning, not a failure. This threshold is about RUNNING the checkpoint; it says
    # nothing about building the engine or running the test suite, both of which need no
    # weights and pass comfortably here. `make test`'s own ceiling is the ~1.7 GB single
    # allocation in tests/unit/scale_test.c. Failing the whole check on this number told
    # people their machine was broken when the only thing they could not do was the one
    # thing that needs 1.56 TB of disk they also did not have.
    warn "under 10 GB available, below the floor for running the checkpoint (~8.2 GB peak RSS)"
    printf '  %s      the build and "make test" need no weights and work fine here%s\n' \
        "$DIM" "$RST"
fi

# -------------------------------------------------------------------- storage --
hdr "storage"
TARGET="${MODEL_DIR:-$PWD}"
if [ -d "$TARGET" ]; then
    # df -Pk everywhere: -BG is GNU-only, POSIX -Pk is not.
    AVAIL_DISK=$(df -Pk "$TARGET" 2>/dev/null | awk 'NR==2{print int($4/1048576)}')
    ok "free space at $TARGET: ${AVAIL_DISK:-?} GB"
    # 1.56 TB checkpoint + ~109 GB packed trunk.
    if [ -n "${AVAIL_DISK:-}" ] && [ "$AVAIL_DISK" -lt 1700 ]; then
        warn "the full checkpoint needs ~1.56 TB plus ~109 GB for the packed trunk"
    fi

    printf '  %smeasuring sequential read (2 GB, this takes a moment)…%s\n' "$DIM" "$RST"
    TMPF="$TARGET/.k3_doctor_probe"
    if [ "$OS" = Darwin ] && command -v python3 >/dev/null 2>&1; then
        # Both halves of the probe go through F_NOCACHE, because HALF is not enough:
        # F_NOCACHE stops pages entering the cache but does not evict ones already
        # there, so a buffered write followed by an F_NOCACHE read still reads RAM.
        # (Observed: ~30 GB/s "disk" on a machine whose device does ~6.) Random-ish
        # data rather than zeros, so nothing between here and the flash can elide it.
        # This is how the engine reads on Darwin, so this rate is the engine's rate.
        RATE=$(python3 - "$TMPF" <<'PY'
import fcntl, os, sys, time
F_NOCACHE = 48
path = sys.argv[1]
blk = os.urandom(4 << 20)
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
fcntl.fcntl(fd, F_NOCACHE, 1)
for _ in range(512):
    os.write(fd, blk)
os.fsync(fd)
os.close(fd)
fd = os.open(path, os.O_RDONLY)
fcntl.fcntl(fd, F_NOCACHE, 1)
t0 = time.monotonic(); n = 0
while True:
    b = os.read(fd, 4 << 20)
    if not b: break
    n += len(b)
os.close(fd)
print(f"{n / (time.monotonic() - t0) / 1e6:.0f} MB/s (F_NOCACHE, as the engine reads)")
PY
) && WROTE=1
    elif [ "$OS" = Darwin ]; then
        # BSD dd: numeric bs (the K/M suffixes are not portable across dd versions)
        # and no conv=fsync; a plain sync afterwards serves the same purpose.
        WROTE=$(dd if=/dev/zero of="$TMPF" bs=1048576 count=2048 2>/dev/null && sync && echo 1)
    else
        WROTE=$(dd if=/dev/zero of="$TMPF" bs=1M count=2048 conv=fsync 2>/dev/null && echo 1)
    fi
    if [ -n "${WROTE:-}" ]; then
        if [ "$OS" = Darwin ] && [ -n "${RATE:-}" ]; then
            :   # probe above already produced the rate
        elif [ "$OS" = Darwin ]; then
            # No python3: BSD dd reads back through the page cache, so this is an
            # upper bound, not a device rate. Say so rather than let it mislead.
            RATE=$(dd if="$TMPF" of=/dev/null bs=4194304 2>&1 \
                   | awk '/bytes transferred/{gsub(/[()]/,""); printf "%.0f MB/s (cached read; install python3 for a device rate)", $(NF-1)/1e6}')
        else
            RATE=$(dd if="$TMPF" of=/dev/null bs=4194304 2>&1 | awk '/copied/{print $(NF-1)" "$NF}')
        fi
        rm -f "$TMPF"
        ok "sequential read: ${RATE:-unknown}"
        printf '  %sthe engine streams ~135 GB per token; storage is usually the ceiling%s\n' "$DIM" "$RST"
    else
        warn "could not write a probe file to $TARGET"
        rm -f "$TMPF" 2>/dev/null
    fi
else
    warn "no model directory given; pass one as the first argument to check its storage"
fi

# ---------------------------------------------------------------- model files --
if [ -n "$MODEL_DIR" ]; then
    hdr "model"
    # find, not `ls | wc -l`: a glob matching nothing would abort the script under
    # `set -euo pipefail` instead of reporting zero shards.
    N=$(find "$MODEL_DIR" -maxdepth 1 -name '*.safetensors' | wc -l)
    if [ "$N" -eq 0 ]; then
        warn "no .safetensors shards in $MODEL_DIR, run scripts/download-model.sh"
    else
        ok "shards present: $N"
        [ "$N" -eq 96 ] || warn "expected 96 shards for the full checkpoint"
    fi
    for f in config.json tiktoken.model tokenizer_config.json; do
        [ -f "$MODEL_DIR/$f" ] && ok "$f" || warn "$f missing (needed for text in/out)"
    done
fi

hdr "result"
if [ "$FAILED" -eq 0 ]; then
    if [ -n "$PRESET" ]; then
        printf '  %sthis machine can run Kimi K3%s\n' "$GRN" "$RST"
    else
        printf '  %sthis machine can build and test the engine, but not run the checkpoint%s\n' \
            "$YLW" "$RST"
    fi

    # The command printed here is the one a user is most likely to copy, so every part
    # of it has to work as written:
    #   --tok    is REQUIRED by --prompt. Without it the engine exits 2 rather than
    #            guessing where the tokenizer lives.
    #   --trunk  is what makes the preset mean anything. Omit it and the trunk loads
    #            fully resident at ~110 GB, which is the opposite of the budget just
    #            recommended.
    # MODEL_DIR is substituted when one was given, so the line can be pasted verbatim.
    if [ -n "$PRESET" ]; then
        M="${MODEL_DIR:-<model_dir>}"
        printf '\n  next:\n'
        printf '    %smake -j%s\n' "$DIM" "$RST"
        printf '    %s./scripts/pack-trunk.sh %s ~/k3trunk%s\n' "$DIM" "$M" "$RST"
        printf '    %s./bin/k3 %s --trunk ~/k3trunk --preset %s \\%s\n' "$DIM" "$M" "$PRESET" "$RST"
        printf '    %s         --tok %s --prompt "Hello" --gen 8 --incremental%s\n' "$DIM" "$M" "$RST"
    else
        # No preset fits, but the weightless path always does, and it is the whole of
        # the README's Quick start. Printing nothing here was what made the old FAIL
        # read as "give up".
        printf '\n  next:\n'
        printf '    %smake -j%s\n' "$DIM" "$RST"
        printf '    %smake test%s\n' "$DIM" "$RST"
        printf '  %sboth need no checkpoint. Running the model needs ~10 GB of RAM and%s\n' \
            "$DIM" "$RST"
        printf '  %s~1.7 TB of disk; come back with those and re-run this check.%s\n' \
            "$DIM" "$RST"
    fi
    exit 0
else
    printf '  %sblocking problems above%s\n' "$RED" "$RST"
    exit 1
fi
