#!/bin/bash
# auto.sh — --par-auto: a plain loop becomes a `par` block where its shape
# allows, and a program built with the flag gives the plain build's output.
#
# Four loops: an element map and an integer reduction, which become blocks;
# a scan (b[i] = b[i - 1] + …), which the parser wraps but par-check demotes
# to a serial run with a par-auto warning; and a float reduction and a loop
# writing an outer scalar, which the parser leaves alone. Both compilers
# must make the same decisions (ast-diff covers the parse; this checks the
# behaviour on the shipped one).
#
#   bash tests/par/auto.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/auto.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
#define N 200000
u32 a[N];
u32 b[N];
float f[N];
i32 main(void)
    {
    for (u32 i in 0..N)                     // an element map: a block
        a[i] = i * (u32)2654435761;
    u32 total = (u32)0;
    for (u32 i in 0..N)                     // an integer reduction: a block
        total = total + (a[i] >> (u32)3);
    u32 bits = (u32)0;
    for (u32 i in 0..N)                     // the compound form: a block
        bits |= a[i] & (u32)0xff;
    b[0] = (u32)1;
    for (u32 i in 1..N)                     // a scan: wrapped, then demoted
        b[i] = b[i - 1] + (u32)1;
    float fs = 0.0f;
    for (u32 i in 0..N)                     // a float reduction: left alone
        fs = fs + (float)(i & (u32)7);
    u32 last = (u32)0;
    for (u32 i in 0..N)                     // an outer scalar written: left alone
        {
        last = a[i];
        f[i] = (float)last;
        }
    Stdio.printf("%u %u %u %u %u %u\n", total, bits, b[N - 1], (u32)fs, last, (u32)f[N - 1]);
    return (i32)0;
    }
XC
"$XC" -q -H . -O2 "$W/auto.xc" -o "$W/plain" >"$W/b1" 2>&1 || { echo "FAIL auto: plain build"; head -3 "$W/b1"; exit 1; }
"$XC" -q -H . -O2 --par-auto "$W/auto.xc" -o "$W/auto" >"$W/b2" 2>&1 || { echo "FAIL auto: --par-auto build"; head -3 "$W/b2"; exit 1; }
export XCC_SETTINGS_DIR="$W/st"; mkdir -p "$XCC_SETTINGS_DIR"   # a fresh learned store
fail=0
grep -q "par-auto" "$W/b2" || { echo "FAIL auto: no par-auto warning for the scan"; cat "$W/b2"; fail=1; }
[ "$(grep -c 'runs serially' "$W/b2")" = 1 ] || { echo "FAIL auto: expected one demoted loop"; cat "$W/b2"; fail=1; }
want=$("$W/plain")
XC_PAR_REPORT=1 "$W/auto" > "$W/rep" 2>&1      # the report shares stdout with the result
got=$(grep -v '^par: ' "$W/rep" | tail -1)
[ "$want" = "$got" ] || { echo "FAIL auto: outputs differ: plain '$want', --par-auto '$got'"; fail=1; }
# Three blocks ran (the map, the two reductions); the scan ran serially and
# is not reported as a run on any device.
n=$(grep -cE 'par: autopar_[0-9]+:' "$W/rep")
[ "$n" -ge 3 ] || { echo "FAIL auto: expected the auto blocks in the report, saw $n lines"; cat "$W/rep"; fail=1; }
grep -q 'autopar_4' "$W/rep" && { echo "FAIL auto: the scan ran as a block"; fail=1; }
[ $fail = 0 ] && echo "--- auto: pass ---"
exit $fail
