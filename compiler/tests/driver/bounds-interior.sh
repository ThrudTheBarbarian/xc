#!/bin/bash
# bounds-interior.sh — the debug build checks a pointer into a block's middle
# (issue #28).
#
# A function given `a + 3` cannot see where it came from, and the check finds
# no header in front of it. Under -fbounds-check the runtime's table of the
# blocks checks have seen places it, so an index past a's end stops the
# program; in-bounds uses still work, and a block that is freed leaves the
# table. -fbounds-check=light keeps its checks call-free and does not look.
#
#   bash tests/driver/bounds-interior.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/t.xc" <<'XC'
#import "Stdio.xc"

u32 sumFrom(u32* p, u32 n)
{
    u32 s = (u32)0;
    for (u32 i = (u32)0; i < n; i = i + (u32)1)
        s = s + p[i];
    return s;
}

u32 churn(u32 k)
{
    // Blocks made and freed: the table must not keep them.
    u32 t = (u32)0;
    for (u32 r = (u32)0; r < k; r = r + (u32)1)
        {
        u32* b = new u32[100];
        b[(u32)99] = r;
        t = t + sumFrom(b + (u32)90, (u32)10);
        }
    return t;
}

i32 main(i32 argc, u8** argv)
{
    u32* a = new u32[10];
    for (u32 i = (u32)0; i < (u32)10; i = i + (u32)1)
        a[i] = i;
    Stdio.printf("%u %u\n", sumFrom(a + (u32)3, (u32)argc + (u32)6), churn((u32)200));
    Stdio.printf("%u\n", sumFrom(a + (u32)3, (u32)argc + (u32)7));
    return 0;
}
XC
fail=0
n=0
for o in -O0 -O2; do
    n=$((n + 1))
    "$XC" -q $o -fbounds-check -o "$W/t$n" "$W/t.xc" 2> "$W/err" || { echo "FAIL build $o"; head -3 "$W/err"; fail=1; continue; }
    "$W/t$n" > "$W/out" 2>&1; rc=$?
    [ "$(head -1 "$W/out")" = "42 19900" ] || { echo "FAIL $o in bounds: $(head -1 "$W/out")"; fail=1; }
    [ $rc = 134 ] || { echo "FAIL $o exit $rc, not 134"; fail=1; }
    grep -q 'out-of-bounds access' "$W/out" || { echo "FAIL $o no trap message"; head -3 "$W/out"; fail=1; }
done
"$XC" -q -O2 -fbounds-check=light -o "$W/tl" "$W/t.xc" 2> "$W/err" || { echo "FAIL build light"; fail=1; }
"$W/tl" > "$W/out" 2>&1
[ "$(head -1 "$W/out")" = "42 19900" ] || { echo "FAIL light in bounds: $(head -1 "$W/out")"; fail=1; }
[ $fail = 0 ] && echo "bounds-interior: ok"
exit $fail
