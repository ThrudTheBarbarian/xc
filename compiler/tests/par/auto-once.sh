#!/bin/bash
# auto-once.sh — auto learns a block the program runs once a process
# (2026-11-07).
#
# Each candidate's first run in a process used to be a warm-up only, so a block
# run once per run was never timed: auto kept its first guess for good (the
# Raspberry Pi 5's V3D, 2.5x slower than its four cores). Now the program
# notes that the block ran once, and from the next run each candidate's first
# run is its timing: within a few runs auto has picked, and a run after that
# decides without measuring. Nothing to compare where the host has no GPU.
#
#   bash tests/par/auto-once.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/once.xc" <<'XC'
#import "Stdio.xc"
#define W 1024
i32 main(void)
{
    u32 total = 0;
    for (u32 i in 0..W * W)
        {
        float cx = (float)(i % W) * (3.0f / W) - 2.0f;
        float cy = (float)(i / W) * (3.0f / W) - 1.5f;
        float x = 0.0f;
        float y = 0.0f;
        u32 k = 0;
        while (k < 128 && x * x + y * y < 4.0f)
            {
            float xt = x * x - y * y + cx;
            y = 2.0f * x * y + cy;
            x = xt;
            k = k + 1;
            }
        total = total + k;
        }
    Stdio.printf("%u\n", total);
    return 0;
}
XC
"$XC" -q -H . -O2 "$W/once.xc" -o "$W/once" > "$W/build" 2>&1 || { echo "FAIL auto-once: build"; head -3 "$W/build"; exit 1; }
export XCC_SETTINGS_DIR="$W/st"; mkdir -p "$XCC_SETTINGS_DIR"
run() { XC_PAR_REPORT=1 "$W/once" > "$W/$1" 2>&1; }
run r1
if ! grep -q "hardware key" "$W/r1" || grep -q "hardware key [0-9a-f]* (|" "$W/r1"; then
    echo "SKIP auto-once: no GPU on this host"; exit 0
fi
fail=0
picked=0
for r in 2 3 4 5 6 7 8; do
    run r$r
    grep -q "auto picks\|auto keeps" "$W/r$r" && { picked=$r; break; }
done
[ $picked != 0 ] || { echo "FAIL auto-once: eight runs and auto never picked"; grep -h "par:" "$W"/r* | head -10; fail=1; }
if [ $picked != 0 ]; then
    run after
    if grep -q "auto picks\|auto keeps" "$W/after"; then
        echo "FAIL auto-once: the run after picking measured again"; fail=1
    fi
    [ "$(tail -1 "$W/after")" = "$(tail -1 "$W/r1")" ] || { echo "FAIL auto-once: the answer changed"; fail=1; }
fi
[ $fail = 0 ] && echo "auto-once: ok (picked on run $picked)"
exit $fail
