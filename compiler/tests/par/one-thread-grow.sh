#!/bin/bash
# one-thread-grow.sh — a tiny block auto finds faster on one thread stays on
# one thread when its size grows a little after auto learned it (#461).
#
# The block runs 2000 times, at 300 items for the first 100 runs and at 300
# to 499 after. Auto measures at 300, where one thread takes a microsecond or
# two and waking every CPU thread tens, and learns the one thread. The later
# sizes are within a factor of two of the measured one, so the measurement
# stands for them: they run on one thread too, from the record, with no run
# on the CPU threads after auto picked. They used to run on every CPU thread
# from then on. The answer is the same as on one thread.
#
#   bash tests/par/one-thread-grow.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$([ "$(uname -s)" = Darwin ] && echo osx || echo linux)
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d /tmp/one-thread-grow.XXXX)
trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/grow.xc" <<'EOF'
#import "Stdio.xc"
#import "Par.xc"
#define N 600
float a[N];
float b[N];
i32 main(i32 argc, u8** argv)
    {
    for (u32 i in 0..N) { a[i] = (float)i; b[i] = 1.0f; }
    for (u32 r in 0..2000)
        {
        u32 n = r < 100 ? 300 : 300 + r % 200;
        par { for (u32 i in 0..n) { b[i] = b[i] + a[i] * 0.5f; } }
        }
    Stdio.printf("%.1f %.1f\n", (double)b[299], (double)b[498]);
    return 0;
    }
EOF
"$XC" -q -H . -O2 --par-style=cpu --no-runtime-lib -o "$W/grow" "$W/grow.xc" || { echo "FAIL one-thread-grow: does not build"; exit 1; }
mkdir -p "$W/set"
answer() { grep -v '^par:' "$1" | tail -1; }
XCC_SETTINGS_DIR="$W/set" XC_PAR_REPORT=1 "$W/grow" > "$W/r1" 2>&1; a=$(answer "$W/r1")
grep -q 'auto picks' "$W/r1" || { echo "FAIL one-thread-grow: auto never picked"; cat "$W/r1" | grep -v 'items on\|pieces over' | head; exit 1; }
if grep -q 'picks the CPU on one thread' "$W/r1"; then
    # The CPU threads' runs after the pick: none (the measuring runs come before it).
    after=$(sed -n '/picks the CPU on one thread/,$p' "$W/r1" | grep -c 'pieces over')
    [ "$after" = 0 ] || { echo "FAIL one-thread-grow: $after runs on the CPU threads after auto picked one thread"; fail=1; }
    grep -rq ',one' "$W/set" || { echo "FAIL one-thread-grow: one thread won but the record has no ,one"; fail=1; }
    # The record covers the grown sizes: a second process measures nothing.
    XCC_SETTINGS_DIR="$W/set" XC_PAR_REPORT=1 "$W/grow" > "$W/r2" 2>&1; b=$(answer "$W/r2")
    grep -q 'auto picks\|pieces over' "$W/r2" && { echo "FAIL one-thread-grow: the second process measured or ran on the CPU threads"; fail=1; }
    [ "$a" = "$b" ] || { echo "FAIL one-thread-grow: the second process printed $b, the first $a"; fail=1; }
else
    echo "one-thread-grow: note: all threads won here ($(grep 'auto picks' "$W/r1" | head -1))"
fi
c=$(XC_PAR=cpu XC_PAR_THREADS=1 "$W/grow")
[ "$a" = "$c" ] || { echo "FAIL one-thread-grow: auto printed $a, one thread $c"; fail=1; }
[ $fail = 0 ] && echo "--- one-thread-grow: pass ---"
exit $fail
