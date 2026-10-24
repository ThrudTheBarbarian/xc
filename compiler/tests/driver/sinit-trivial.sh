#!/bin/bash
# sinit-trivial.sh — a static-init guard that only sets its own flag comes out
# (2026-10-24): Math has no static initialiser, so its guard's init block is
# just `flag = 1`, and nothing but its guards reads the flag. Left in a loop
# that calls Math.sqrt it kept the body two blocks, which neither vectoriser
# takes (nbody's inner loop); the hoist to the entry did not always reach it.
# Both compilers, arm64 and x86-64: no __sinit_Math left in main, same answer.
#
#   bash tests/driver/sinit-trivial.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/s.xc" <<'XC'
#import "Stdio.xc"
#import "Math.xc"
#define N 4096
double xs[N];
i32 main(void)
    {
    for (u32 i in 0..N) xs[i] = (double)i;
    double t = 0.0;
    for (u32 i in 0..N)
        t = t + Math.sqrt(xs[i]);
    Stdio.printf("%.3f\n", t);
    return 0;
    }
XC
REF=bin/osx/xcc; XC=bin/osx/xcc-xc
[ "$(uname -s)" = Linux ] && { REF=bin/linux/xcc; XC=bin/linux/xcc-xc; }
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    for a in arm64 x86_64; do
        s="$W/$(basename "$c")-$a.s"
        "$c" -q -A $a -O2 -H . -S -o "$s" "$W/s.xc" || { echo "FAIL $c $a: no assembly"; fail=1; continue; }
        # main up to the next function (arm64's local labels start with L).
        n=$(awk '/^_?main:/{f=1;next} f && /^_?[A-Za-z_][A-Za-z0-9_$]*:$/ && !/^L/{f=0} f' "$s" | grep -c '__sinit_Math')
        [ "$n" = 0 ] || { echo "FAIL $c $a: main still tests __sinit_Math ($n references)"; fail=1; }
    done
done
if [ "$(uname -s)" = Darwin ]; then
    "$XC" -q -O2 -H . -o "$W/s" "$W/s.xc" && "$XC" -q -O0 -H . -o "$W/s0" "$W/s.xc" || { echo "FAIL: build"; fail=1; }
    [ "$("$W/s")" = "$("$W/s0")" ] || { echo "FAIL: -O2 and -O0 differ"; fail=1; }
fi
[ $fail = 0 ] && echo "sinit-trivial: ok"
exit $fail
