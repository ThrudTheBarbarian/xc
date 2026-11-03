#!/bin/bash
# one-thread.sh — auto measures the CPU on one thread too (issue 9).
#
# A block of 20000 cheap items is faster on one thread than on all of them
# (waking the threads costs more than the work): auto times both, learns the
# one thread (`,one` in its learned record), and a second process runs the
# block on one thread straight from the record. The answer is the same in
# every run.
#
#   bash tests/par/one-thread.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$([ "$(uname -s)" = Darwin ] && echo osx || echo linux)
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d /tmp/one-thread.XXXX)
trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/small.xc" <<'EOF'
#import "Stdio.xc"
#import "Par.xc"
#define N 20000
float a[N];
float b[N];
i32 main(i32 argc, u8** argv)
    {
    for (u32 i in 0..N) { a[i] = (float)i; b[i] = 1.0f; }
    for (u32 r in 0..50)
        par { for (u32 i in 0..N) { b[i] = b[i] + a[i] * 0.5f; } }
    Stdio.printf("%.1f\n", (double)b[N - 1]);
    return 0;
    }
EOF
"$XC" -q -H . -O2 --par-style=cpu --no-runtime-lib -o "$W/small" "$W/small.xc" || { echo "FAIL one-thread: does not build"; exit 1; }
mkdir -p "$W/set"
# The reports and the answer share the output: the answer is the line that
# is not a report.
answer() { grep -v '^par:' "$1" | tail -1; }
XCC_SETTINGS_DIR="$W/set" XC_PAR_REPORT=1 "$W/small" > "$W/r1" 2>&1; a=$(answer "$W/r1")
grep -q 'items on one CPU thread' "$W/r1" || { echo "FAIL one-thread: auto never ran the block on one thread"; fail=1; }
if grep -q 'learned' "$W/r1"; then
    # Where one thread won (it does on every machine the gate has: 20000 adds
    # take a few microseconds, a wake of the threads tens), the record says so.
    if grep -q 'picks the CPU on one thread' "$W/r1"; then
        grep -rq ',one' "$W/set" || { echo "FAIL one-thread: one thread won but the record has no ,one"; fail=1; }
        XCC_SETTINGS_DIR="$W/set" XC_PAR_REPORT=1 "$W/small" > "$W/r2" 2>&1; b=$(answer "$W/r2")
        grep -q 'items on one CPU thread\|auto picks' "$W/r2" && { echo "FAIL one-thread: the second process measured again"; fail=1; }
        [ "$a" = "$b" ] || { echo "FAIL one-thread: the second process printed $b, the first $a"; fail=1; }
    else
        echo "one-thread: note: all threads won here ($(grep 'auto picks' "$W/r1" | head -1))"
    fi
fi
c=$(XC_PAR=cpu XC_PAR_THREADS=1 "$W/small")
[ "$a" = "$c" ] || { echo "FAIL one-thread: auto printed $a, one thread $c"; fail=1; }
[ $fail = 0 ] && echo "--- one-thread: pass ---"
exit $fail
