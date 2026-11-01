#!/bin/bash
# one-gpu-set.sh — `gpus` with one GPU runs a bandwidth-bound block in one
# launch, not in tiles on that GPU (2026-11-01).
#
# On a machine with one GPU the set `gpus` holds one device, and ParTiles cut
# the block into tiles on it: each tile's fixed costs and copies, for a block
# that moves more bytes than it computes (saxpy on a Pi 5: 12 tiles 200 ms,
# one launch 132; on an M4 Max 56 ms against 5). Now such a block takes the
# single-GPU path; a compute-bound one keeps its tiles. Checked here with
# XC_PAR=gpus: the answer, and that the block is not reported as tiles across
# exactly one device. A machine with no GPU, or with several, has nothing to
# check and passes.
#
#   bash tests/par/one-gpu-set.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
cat > "$W/sax.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
i32 main(void)
    {
    u32 n = (u32)4194304;
    float* x = new float[n];
    float* y = new float[n];
    for (u32 i = (u32)0; i < n; i = i + (u32)1)
        {
        x[i] = (float)(i & (u32)1023);
        y[i] = 1.0f;
        }
    par sax
        {
        for (u32 i in 0..n)
            y[i] = 2.0f * x[i] + y[i];
        }
    Stdio.printf("%.1f %.1f\n", (double)y[(u32)7], (double)y[n - (u32)1]);
    return (i32)0;
    }
XC
"$XC" -q -O2 -o "$W/sax" "$W/sax.xc" > "$W/e" 2>&1 || { echo "FAIL one-gpu-set: no build: $(head -c 200 "$W/e")"; exit 1; }
mkdir -p "$W/st"
XCC_SETTINGS_DIR="$W/st" XC_PAR=gpus XC_PAR_REPORT=1 "$W/sax" > "$W/out" 2>&1
grep -qx '15.0 2047.0' "$W/out" || { echo "FAIL one-gpu-set: wrong answer: $(grep -v '^par:' "$W/out" | head -c 200)"; fail=1; }
# "tiles across <one device> (" — a single device, no comma between devices.
if grep -E 'sax: [0-9]+ items in [0-9]+ tiles across [^,]+ \(' "$W/out" > "$W/one"; then
    echo "FAIL one-gpu-set: a bandwidth-bound block was tiled on one GPU:"; cat "$W/one"; fail=1
fi
[ $fail = 0 ] && echo "one-gpu-set: ok"
exit $fail
