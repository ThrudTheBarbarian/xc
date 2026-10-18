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
export XC_PAR_REMOTE=none     # discovery is on by default; this test names no daemon
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
    u32 least = (u32)$FFFFFFFF;
    for (u32 i in 0..N)                     // keeps the smallest: a min reduction (0.8.1)
        if (a[i] < least)
            least = a[i];
    u32 most = (u32)0;
    for (u32 i in 0..N)                     // the accumulator on the left: a max
        if (most < c[i])
            most = c[i];
    Stdio.printf("%u %u %u %u %u %u %u %u %u %u %u %u %u\n", total, bits, b[N - 1], (u32)fs, last, (u32)f[N - 1], c[N - 1], inc, count, gs, odd, least, most);
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
for k in 12 13; do grep -q "autopar_$k:" "$W/rep" || { echo "FAIL auto: block autopar_$k (min / max) did not run"; fail=1; }; done
grep -q 'autopar_14' "$W/rep" && { echo "FAIL auto: a fourteenth block ran (the :serial loop?)"; fail=1; }
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
# A C-style loop on a variable declared OUTSIDE it (`for (i = 0; …)`) is not
# a block: its work items would have no variable of their own. The scan took
# it, and both compilers then refused the whole program (2026-10-17).
cat > "$W/outer.xc" <<'XC'
#import "Stdio.xc"
i32 main(void)
    {
    u32 total = (u32)0;
    u16 i = (u16)0;
    for (i = (u16)0; i < (u16)10; i = i + (u16)1)
        total = total + (u32)i;
    Stdio.printf("%u %u\n", total, (u32)i);
    return 0;
    }
XC
"$XC" -q -H . -O2 --par-auto -Wpar-auto "$W/outer.xc" -o "$W/outer" >"$W/b6" 2>&1 || { echo "FAIL auto: a loop on an outer variable broke the --par-auto build"; head -3 "$W/b6"; fail=1; }
grep -q "became a 'par' block" "$W/b6" && { echo "FAIL auto: a loop on an outer variable became a block"; fail=1; }
[ -x "$W/outer" ] && [ "$("$W/outer")" = "45 10" ] || { echo "FAIL auto: the outer-variable loop's output"; fail=1; }
# A program that does not import the par runtime: --par-auto imports it
# itself when a loop becomes a block (the build failed with "a 'par' block
# needs its runtime" in 0.85), and only then — a program with nothing to wrap
# does not carry the runtime.
cat > "$W/noruntime.xc" <<'XC'
#import "Stdio.xc"
i32 main(void)
    {
    i32 a[64];
    for (i32 i = 0; i < 64; i = i + 1) a[i] = i;
    i32 s = 0;
    for (i32 i = 0; i < 64; i = i + 1) s = s + a[i];
    Stdio.printf("%ld\n", s);
    return 0;
    }
XC
"$XC" -q -H . -O2 --par-auto -Wpar-auto "$W/noruntime.xc" -o "$W/noruntime" >"$W/b7" 2>&1 || { echo "FAIL auto: --par-auto broke a program without the par runtime"; head -3 "$W/b7"; fail=1; }
grep -q "became a 'par' block" "$W/b7" || { echo "FAIL auto: --par-auto did not import the runtime for a program without it"; fail=1; }
[ -x "$W/noruntime" ] && [ "$("$W/noruntime")" = "2016" ] || { echo "FAIL auto: the no-runtime program's output"; fail=1; }
cat > "$W/nothing.xc" <<'XC'
#import "Stdio.xc"
i32 main(void)
    {
    i32 s = 1;
    for (i32 i = 0; i < 10; i = i + 1) s = s * 3 + i;
    Stdio.printf("%ld\n", s);
    return 0;
    }
XC
"$XC" -q -H . -O2 --par-auto "$W/nothing.xc" -o "$W/nothing" >"$W/b8" 2>&1 || { echo "FAIL auto: --par-auto broke a program with nothing to wrap"; head -3 "$W/b8"; fail=1; }
[ -x "$W/nothing" ] && [ "$("$W/nothing")" = "73806" ] || { echo "FAIL auto: the nothing-to-wrap program's output"; fail=1; }
nm "$W/nothing" 2>/dev/null | grep -q 'ParChunk' && { echo "FAIL auto: a program with nothing to wrap carries the par runtime"; fail=1; }
# `acc = acc op e` is a reduction only when op joins all of e. In a Horner
# hash, `h = h * C + x`, the + binds outside the *: the iterations depend on
# each other, and wrapping it gave 0 (par_gpu_wide, 2026-10-17).
cat > "$W/horner.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
#define N 4096
u64 xs[N];
i32 main(void)
    {
    for (u32 i in 0..N)
        xs[i] = (u64)i * (u64)2654435761;
    u64 h = (u64)1469598103934665603;
    for (u32 i in 0..N)
        h = h * (u64)1099511628211 + xs[i];
    u64 s = (u64)0;
    for (u32 i in 0..N)
        s = s + xs[i] * (u64)3;
    Stdio.printf("%llx %llx\n", h, s);
    return 0;
    }
XC
"$XC" -q -H . -O2 "$W/horner.xc" -o "$W/horner0" >/dev/null 2>&1
"$XC" -q -H . -O2 --par-auto -Wpar-auto "$W/horner.xc" -o "$W/horner1" >"$W/b8" 2>&1 || { echo "FAIL auto: the Horner program did not build"; fail=1; }
grep -q "horner.xc:10:.*became a 'par' block" "$W/b8" && { echo "FAIL auto: a Horner hash became a block"; fail=1; }
grep -q "horner.xc:13:.*became a 'par' block" "$W/b8" || { echo "FAIL auto: s = s + xs[i] * 3 (a + reduction) did not become a block"; cat "$W/b8"; fail=1; }
[ "$("$W/horner0")" = "$("$W/horner1")" ] || { echo "FAIL auto: the Horner program's output differs under --par-auto"; fail=1; }
[ $fail = 0 ] && echo "--- auto: pass ---"
exit $fail
