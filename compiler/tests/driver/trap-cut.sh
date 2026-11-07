#!/bin/bash
# trap-cut.sh — a failed bounds check's trap ends its block (issue #28).
#
# Under -fbounds-check=light the inlined checks call _xt_check_trap, which
# never returns. The optimiser ends that path with Unreachable, so a loop that
# checks holds no call for it. The trap must still fire, with its message and
# exit code, for an index that is out of bounds.
#
#   bash tests/driver/trap-cut.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/t.xc" <<'XC'
#import "Stdio.xc"

u32 sumTo(u32* a, u32 n)
{
    u32 s = (u32)0;
    for (u32 i = (u32)0; i < n; i = i + (u32)1)
        s = s + a[i];
    return s;
}

i32 main(void)
{
    u32* a = new u32[10];
    for (u32 i = (u32)0; i < (u32)10; i = i + (u32)1)
        a[i] = i;
    Stdio.printf("%u\n", sumTo(a, (u32)10));
    Stdio.printf("%u\n", sumTo(a, (u32)11));
    return 0;
}
XC
fail=0
"$XC" -q -O2 -fbounds-check=light --emit-ir-opt -o "$W/t" "$W/t.xc" 2> "$W/ir" || { echo "FAIL build"; head -3 "$W/ir"; exit 1; }
traps=$(grep -c 'Call @_xt_check_trap' "$W/ir")
cut=$(grep -A1 'Call @_xt_check_trap' "$W/ir" | grep -c 'Unreachable')
[ "$traps" -gt 0 ] && [ "$traps" = "$cut" ] || { echo "FAIL $cut of $traps trap calls end their block"; fail=1; }
"$W/t" > "$W/out" 2>&1; rc=$?
[ "$(head -1 "$W/out")" = "45" ] || { echo "FAIL the in-bounds sum: $(head -1 "$W/out")"; fail=1; }
[ $rc = 134 ] || { echo "FAIL exit $rc, not 134"; fail=1; }
grep -q 'out-of-bounds access' "$W/out" || { echo "FAIL no trap message"; head -5 "$W/out"; fail=1; }
[ $fail = 0 ] && echo "trap-cut: ok"
exit $fail
