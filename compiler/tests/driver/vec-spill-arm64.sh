#!/bin/bash
# vec-spill-arm64.sh — arm64 spills a vector that is not a constant
# (2026-10-24, the rest of #11): a loop body holding more non-constant vectors
# at once than the pool has stopped the build ("vector register pressure
# exceeded the 14-register pool"); only a constant splat could be given up. A
# vector given up now has a 16-byte frame slot of its own, stored where it is
# defined and loaded into a scratch register where it is read. Both compilers
# print the same code, and it gives -O0's answer. macOS arm64 hosts.
#
#   bash tests/driver/vec-spill-arm64.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
[ "$(uname -s)-$(uname -m)" = Darwin-arm64 ] || { echo "vec-spill-arm64: arm64 macOS only, skipped"; exit 0; }
REF=bin/osx/xcc; XC=${XC:-bin/osx/xcc-xc}
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/p.xc" <<'XC'
#import "Stdio.xc"
#define N 4096
u32 xs[N];
i32 main(void)
    {
    for (u32 i in 0..N) xs[i] = i * (u32)2654435761;
    u32 total = (u32)0;
    for (u32 i in 0..N)
        {
        u32 x = xs[i];
        u32 v0 = (x * (u32)653163) ^ (x >> 1);
        u32 v1 = (x * (u32)267857) ^ (x >> 2);
        u32 v2 = (x * (u32)777823) ^ (x >> 3);
        u32 v3 = (x * (u32)375955) ^ (x >> 4);
        u32 v4 = (x * (u32)833823) ^ (x >> 5);
        u32 v5 = (x * (u32)723989) ^ (x >> 6);
        u32 v6 = (x * (u32)988233) ^ (x >> 7);
        u32 v7 = (x * (u32)882391) ^ (x >> 8);
        u32 v8 = (x * (u32)775843) ^ (x >> 9);
        u32 v9 = (x * (u32)683707) ^ (x >> 10);
        u32 v10 = (x * (u32)967131) ^ (x >> 11);
        u32 v11 = (x * (u32)555791) ^ (x >> 12);
        total = total + v0 * v11 + v1 * v10 + v2 * v9 + v3 * v8 + v4 * v7 + v5 * v6;
        }
    Stdio.printf("%u\n", total);
    return 0;
    }
XC
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    "$c" -q -O2 -H . -S -o "$W/$(basename "$c").s" "$W/p.xc" > "$W/b" 2>&1 || { echo "FAIL $c: $(head -1 "$W/b")"; fail=1; }
done
[ -s "$W/xcc-xc.s" ] && { grep -q 'str q[0-9]*, \[sp' "$W/xcc-xc.s" || { echo "FAIL: nothing spilled (the case no longer tests the spill)"; fail=1; }; }
if [ -s "$W/xcc.s" ] && [ -s "$W/xcc-xc.s" ] && ! cmp -s "$W/xcc.s" "$W/xcc-xc.s"; then echo "FAIL: the two compilers' code differs"; fail=1; fi
"$XC" -q -O2 -H . -o "$W/p2" "$W/p.xc" && "$XC" -q -O0 -H . -o "$W/p0" "$W/p.xc" || { echo "FAIL: build"; fail=1; }
[ -x "$W/p2" ] && [ "$("$W/p2")" = "$("$W/p0")" ] || { echo "FAIL: -O2 and -O0 differ"; fail=1; }
[ $fail = 0 ] && echo "vec-spill-arm64: ok"
exit $fail
