#!/bin/bash
# auto.sh — --par-auto: a plain loop becomes a `par` block where its shape
# allows, and a program built with the flag gives the plain build's output.
#
# The loops: an element map and an integer reduction, which become blocks;
# a scan (b[i] = b[i - 1] + …), which the parser wraps but par-check demotes
# to a serial run with a par-auto warning; a float reduction and a loop
# writing an outer scalar, which the parser leaves alone; and a map marked
# :serial, left alone by request. Then the same file under `#goal speed`,
# where the float reduction becomes a block too. The par-auto warnings are
# opt-in (-Wpar-auto): a build without the flag must say nothing. Both
# compilers must make the same decisions (ast-diff covers the parse; this
# checks the behaviour on the shipped one).
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
u32 c[N];
#define W 640
#define H 480
u32 g[W * H];
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
    for (u32 i in 0..N) : serial            // marked serial: left alone
        a[i] = a[i] ^ (u32)1;
    for (u32 i = (u32)0; i < N; i++)         // C-style: a block (from 0.8.1)
        c[i] = a[i] + (u32)7;
    u32 inc = (u32)0;
    for (u32 i in 0...N - 1)                 // an inclusive range: a block
        inc = inc + (c[i] & (u32)3);
    u32 count = (u32)0;
    for (u32 i = (u32)0; i <= N - (u32)1; i += 1)        // <= and += 1
        {
        if ((c[i] & (u32)1) != (u32)0)
            count++;                         // acc++: a + reduction
        }
    block void(void) inBlock = block void(void)   // a loop inside a block literal: a block too
        {
        for (u32 i in 0..N)
            b[i] = b[i] ^ (u32)5;
        };
    inBlock();
    for (u32 i in 0..H)                     // a perfect nest: one block over the W*H grid
        for (u32 j in 0..W)
            g[i * W + j] = (u32)(i * 3) ^ (u32)j;
    u32 gs = (u32)0;
    for (u32 i in 0..H * W)
        gs = gs ^ g[i];
    u32 odd = (u32)0;
    for (u32 i in 0..N)                     // a bare if as the body (no braces): a block
        if ((a[i] & (u32)1) != (u32)0)
            odd++;
    Stdio.printf("%u %u %u %u %u %u %u %u %u %u %u\n", total, bits, b[N - 1], (u32)fs, last, (u32)f[N - 1], c[N - 1], inc, count, gs, odd);
    return (i32)0;
    }
XC
"$XC" -q -H . -O2 "$W/auto.xc" -o "$W/plain" >"$W/b1" 2>&1 || { echo "FAIL auto: plain build"; head -3 "$W/b1"; exit 1; }
"$XC" -q -H . -O2 --par-auto "$W/auto.xc" -o "$W/quiet" >"$W/b0" 2>&1 || { echo "FAIL auto: --par-auto build"; head -3 "$W/b0"; exit 1; }
"$XC" -q -H . -O2 --par-auto -Wpar-auto "$W/auto.xc" -o "$W/auto" >"$W/b2" 2>&1 || { echo "FAIL auto: --par-auto -Wpar-auto build"; head -3 "$W/b2"; exit 1; }
export XCC_SETTINGS_DIR="$W/st"; mkdir -p "$XCC_SETTINGS_DIR"   # a fresh learned store
fail=0
[ -s "$W/b0" ] && { echo "FAIL auto: a build without -Wpar-auto printed:"; cat "$W/b0"; fail=1; }
grep -q "par-auto" "$W/b2" || { echo "FAIL auto: no par-auto warning for the scan"; cat "$W/b2"; fail=1; }
[ "$(grep -c 'runs serially' "$W/b2")" = 1 ] || { echo "FAIL auto: expected one demoted loop"; cat "$W/b2"; fail=1; }
want=$("$W/plain")
XC_PAR_REPORT=1 "$W/auto" > "$W/rep" 2>&1      # the report shares stdout with the result
got=$(grep -v '^par: ' "$W/rep" | tail -1)
[ "$want" = "$got" ] || { echo "FAIL auto: outputs differ: plain '$want', --par-auto '$got'"; fail=1; }
# Six blocks ran (the map, the two reductions, the C-style map, the inclusive
# reduction and the count); the scan ran serially and is not reported as a
# run on any device, and the :serial loop is no block at all, so the blocks
# are numbered 1-4 and 5-7.
n=$(grep -cE 'par: autopar_[0-9]+:' "$W/rep")
[ "$n" -ge 10 ] || { echo "FAIL auto: expected the auto blocks in the report, saw $n lines"; cat "$W/rep"; fail=1; }
grep -q 'autopar_4' "$W/rep" && { echo "FAIL auto: the scan ran as a block"; fail=1; }
for k in 5 6 7 8 9 10 11; do grep -q "autopar_$k:" "$W/rep" || { echo "FAIL auto: block autopar_$k (C-style / inclusive / acc++ / block literal / nest / xor / bare if) did not run"; fail=1; }; done
grep -q 'autopar_12' "$W/rep" && { echo "FAIL auto: a twelfth block ran (the :serial loop?)"; fail=1; }
# The nest ran as ONE block over the whole grid (640*480 items), not as 480
# blocks of 640, and the reduction after it (autopar_10) is a block of its own.
grep -q 'autopar_9: 307200 items' "$W/rep" || { echo "FAIL auto: the perfect nest did not run as one 307200-item grid block"; grep autopar_9 "$W/rep" | head -3; fail=1; }
# Under `#goal speed` the float reduction is a block too (its sum may
# reassociate; the goal says that is wanted), and the result still agrees.
{ echo '#goal speed'; cat "$W/auto.xc"; } > "$W/speed.xc"
"$XC" -q -H . -O2 --par-auto "$W/speed.xc" -o "$W/speed" >"$W/b3" 2>&1 || { echo "FAIL auto: #goal speed build"; head -3 "$W/b3"; exit 1; }
XC_PAR_REPORT=1 "$W/speed" > "$W/rep2" 2>&1
got2=$(grep -v '^par: ' "$W/rep2" | tail -1)
[ "$want" = "$got2" ] || { echo "FAIL auto: outputs differ under #goal speed: plain '$want', got '$got2'"; fail=1; }
n2=$(grep -cE 'par: autopar_[0-9]+:' "$W/rep2")
[ "$n2" -gt "$n" ] || { echo "FAIL auto: #goal speed did not add the float reduction ($n2 vs $n lines)"; cat "$W/rep2" | head -20; fail=1; }
# -fgoal=accuracy on the same file: the directive wins over the flag.
"$XC" -q -H . -O2 --par-auto -fgoal=accuracy "$W/speed.xc" -o "$W/speed2" >"$W/b4" 2>&1 || { echo "FAIL auto: -fgoal=accuracy build"; head -3 "$W/b4"; exit 1; }
XC_PAR_REPORT=1 "$W/speed2" > "$W/rep3" 2>&1
n3=$(grep -cE 'par: autopar_[0-9]+:' "$W/rep3")
[ "$n3" = "$n2" ] || { echo "FAIL auto: -fgoal=accuracy overrode #goal speed ($n3 vs $n2)"; fail=1; }
# -fgoal=speed alone (no directive) wraps the float reduction as the directive did.
"$XC" -q -H . -O2 --par-auto -fgoal=speed "$W/auto.xc" -o "$W/speed3" >"$W/b5" 2>&1 || { echo "FAIL auto: -fgoal=speed build"; head -3 "$W/b5"; exit 1; }
XC_PAR_REPORT=1 "$W/speed3" > "$W/rep4" 2>&1
n4=$(grep -cE 'par: autopar_[0-9]+:' "$W/rep4")
[ "$n4" = "$n2" ] || { echo "FAIL auto: -fgoal=speed wrapped $n4 blocks, #goal speed $n2"; fail=1; }
[ $fail = 0 ] && echo "--- auto: pass ---"
exit $fail
