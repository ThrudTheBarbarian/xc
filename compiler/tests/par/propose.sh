#!/bin/bash
# propose.sh — IR Propose's report (XC_PAR_PROPOSE=report, step 1 of moving
# --par-auto's search into the IR): the loops it names, and the shapes.
# Self-hosted compiler only while the report is experimental; the corpus
# comparison with the parser's scan is selfhost/tools/propose-diff.sh.
#
#   bash tests/par/propose.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/p.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
#define N 300
u32 m[N * N];
u32 r[N];
i32 main(void)
    {
    for (u32 i in 0..N)
        for (u32 j in 0..i + (u32)1)
            m[i * N + j] = i + j;
    for (u32 i in 0..N)
        for (u32 j in 0..N)
            m[i * N + j] = m[i * N + j] + (u32)1;
    for (u32 i in 0..N)
        {
        u32 t = (u32)0;
        for (u32 j in i..N)
            t = t + m[i * N + j];
        r[i] = t;
        }
    u64 h = (u64)1469598103934665603;
    for (u32 i in 0..N)
        h = h * (u64)1099511628211 + (u64)r[i];
    u32 k = (u32)0;
    while (k < (u32)N)
        {
        if (r[k] > (u32)100000)
            break;
        k++;
        }
    Stdio.printf("%u %u %llx %u\n", m[N * N - 1], r[0], h, k);
    return 0;
    }
XC
XC_PAR_PROPOSE=report "$XC" -q -H . -o "$W/p" "$W/p.xc" > "$W/out" 2>&1 || { echo "FAIL propose: the build"; head -3 "$W/out"; exit 1; }
want() { grep -q "p.xc:$1: $2" "$W/out" || { echo "FAIL propose: line $1 should say '$2'"; grep 'propose:' "$W/out"; fail=1; }; }
want 8 'wrap'
want 8 'shape triangular'
want 11 'wrap'
want 14 'wrap'
want 14 'shape triangular'
want 22 'no (a carried value that is not an accumulator)'
want 25 'no (a way out of the loop besides its test'
grep -q 'p.xc:11: shape' "$W/out" && { echo "FAIL propose: the square nest is not triangular"; fail=1; }
# The report changes nothing: the program's output is the plain build's.
"$XC" -q -H . -o "$W/q" "$W/p.xc" >/dev/null 2>&1
[ "$("$W/p")" = "$("$W/q")" ] || { echo "FAIL propose: the report build's output differs"; fail=1; }
[ $fail = 0 ] && echo "--- propose: pass ---"
