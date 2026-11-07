#!/bin/bash
# bounds-origin.sh — a pointer made by `a + k` is checked against a (issue #28).
#
# The heap check reads the block header at the pointer it is given, and a
# pointer into the middle of an array has none there, so `q = a + 4; q[6]`
# went unchecked. Now it is checked as a[10], at every optimisation level and
# in both check modes; in-bounds uses, a negative step included, still work.
#
#   bash tests/driver/bounds-origin.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/t.xc" <<'XC'
#import "Stdio.xc"

i32 main(i32 argc, u8** argv)
{
    u32* a = new u32[10];
    for (u32 i = (u32)0; i < (u32)10; i = i + (u32)1)
        a[i] = i;
    u32* q = a + (u32)4;
    u32* r = q + (u32)3;
    i32 back = (i32)0 - (i32)2;
    Stdio.printf("%u %u %u\n", q[(u32)argc + (u32)4], r[back], r[(u32)argc + (u32)1]);
    Stdio.printf("%u\n", q[(u32)argc + (u32)5]);
    return 0;
}
XC
fail=0
# A binary of its own per build: macOS kills a re-signed one rebuilt in place.
n=0
for mode in "-fbounds-check" "-fbounds-check=light"; do
    for o in -O0 -O2; do
        n=$((n + 1))
        "$XC" -q $o $mode -o "$W/t$n" "$W/t.xc" 2> "$W/err" || { echo "FAIL build $o $mode"; head -3 "$W/err"; fail=1; continue; }
        "$W/t$n" > "$W/out" 2>&1; rc=$?
        [ "$(head -1 "$W/out")" = "9 5 9" ] || { echo "FAIL $o $mode in bounds: $(head -1 "$W/out")"; fail=1; }
        [ $rc = 134 ] || { echo "FAIL $o $mode exit $rc, not 134"; fail=1; }
        grep -q 'out-of-bounds access' "$W/out" || { echo "FAIL $o $mode no trap message"; head -3 "$W/out"; fail=1; }
    done
done
[ $fail = 0 ] && echo "bounds-origin: ok"
exit $fail
