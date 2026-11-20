#!/bin/bash
# auto-check.sh — the --par-style=auto recogniser's verdicts on the header
# spellings and the loops below, against an expected list
# (tests/par/auto-check.expected): XC_PAR_AUTO_TRACE=1 gives one line for each
# loop, with its verdict, the rule that decided it, its form, and for a block
# its name, reductions, grid rank and ParImpl number. The header loops read
# the source facts the parser puts on a loop (range syntax, `: serial`, a
# `: goal` of its own, a range step that is not a plain literal, literal
# bounds that descend, and the condition and step spellings); the others
# exercise each rule the recogniser reads from the token beside a name, and
# the loops it reads through a site. The trace must not change the output:
# the assembly is compared with it on and off.
#
#   bash tests/par/auto-check.sh                   # bin/<plat>/xcc-xc
#   XC=path/to/xcc bash tests/par/auto-check.sh
#   UPDATE=1 bash tests/par/auto-check.sh          # rewrite the expected list
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 2
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
[ -x "$XC" ] || { echo "auto-check: no compiler at $XC"; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/auto-check.XXXXXX")
trap 'rm -rf "${W:?}"' EXIT

cat > "$W/headers.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
#define N 100000
u32 a[N];
u32 f1(u32 x) { return x + 1; }
i32 main(void)
{
    u32 n = N;
    u32 step = 50;
    bool ok = true;
    for (u32 i in 0..n) a[i] = i;
    for (u32 i in 0..n step 2) a[i] = 1;
    for (u32 i in 0...n step 3) a[i] = 2;
    for (u32 i in 0..step) a[i] = 3;
    for (u32 i in 0..(step)) a[i] = 4;
    for (u32 i in 0..step + 1) a[i] = 5;
    for (u32 i in 0..f1(step)) a[i] = 6;
    for (i32 i in 10..0) a[i] = 7;
    for (i32 i in $10..0) a[i] = 8;
    for (i32 i in 0x10..0) a[i] = 8;
    for (i32 i in 10..0 step -2) a[i] = 9;
    for (u32 i in 0..n) : serial { a[i] = 10; }
    for (u32 i in 0..n) : goal(speed) { a[i] = 11; }
    for (u32 i in 0..n) : unroll, goal(accuracy) { a[i] = 12; }
    for (u32 i = 0; i < n; i++) a[i] = 13;
    for (u32 i = 0; i < n; ++i) a[i] = 14;
    for (u32 i = 0; i < n; i += 1) a[i] = 15;
    for (u32 i = 0; i < n; i = i + 1) a[i] = 16;
    for (u32 i = 0; i < n; i += 0x1) a[i] = 17;
    for (u32 i = 0; i < n; i += 01) a[i] = 18;
    for (u32 i = 0; i < n; i += $1) a[i] = 18;
    for (u32 i = 0; i < n; i = (i + 1)) a[i] = 19;
    for (u32 i = 0; i < n; (i)++) a[i] = 20;
    for (u32 i = 0; i < n; i += (1)) a[i] = 21;
    for (u32 i = 0; i < n; i += (u32)1) a[i] = 22;
    for (u32 i = 0; i < n; i = i + (u32)1) a[i] = 23;
    for (u32 i = 0; i < n; i = 1 + i) a[i] = 24;
    for (u32 i = 0; i < n; i += 2) a[i] = 25;
    for (u32 i = 0; (i) < n; i++) a[i] = 26;
    for (u32 i = 0; i < n && ok; i++) a[i] = 27;
    for (u32 i = 0; i <= n - 1; i++) a[i] = 28;
    for (u32 i = 0; n > i; i++) a[i] = 29;
    for (u32 i = 0; i + 0 < n; i++) a[i] = 30;
    for (u32 i = 0; i < n; i++) : serial a[i] = 31;
    for (u32 i = 0; i < n; i++) : goal(speed) a[i] = 32;
    u32 v = 0;
    while (v < n) { a[v] = 34; v++; }
    u32 s = 0;
    for (u32 i in 0..n) s += a[i];
    Stdio.printf("%u\n", s);
    return 0;
}
XC

# Loops that exercise each rule the recogniser reads from the token before or
# after a name, and the ones it reads through a site.
cat > "$W/recog.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
#define N 100000
u32 a[N];
u32 b[N];
i32 c[N];
float fa[N];
u32 g2[90000];
struct S { u32 n; u32 v; u32 acc; };
S gs;
u32 f1(u32 x) { return x + 1; }
class K
    {
    u32 _k;
    void init(void) { _k = 1; }
    u32 twice(u32 x) { return x * 2; }
    void run(void)
        {
        for (u32 i = 0; i < N; i++) a[i] = twice(i);
        }
    }
i32 main(void)
{
    u32 n = N;
    u32 acc = 0;
    u32 acc2 = 0;
    i32 sacc = 0;
    u32 mask = 7;
    u32 m = 4000000000;
    u32 serial = 0;
    u32 total = N;
    float fs = 0.0;
    u32 q = 0;
    // A statement starts after `)`, so a cast's operand counts: `acc++;`.
    for (u32 i = 0; i < n; i++) { u32 y = (u32)acc++; b[i] = y; }
    // `expr & name` takes the name's address unless `[` follows.
    for (u32 i = 0; i < n; i++) b[i] = a[i] & mask;
    for (u32 i = 0; i < n; i++) b[i] = a[i] & a[0];
    // `++` next to a name that is not the body's own, a member's too.
    for (u32 i = 0; i < n; i++) { gs.n++; b[i] = 1; }
    for (u32 i = 0; i < n; i++) { S t; t.n = i; t.n++; b[i] = t.n; }
    // A name after a cast and before `:` reads as a label.
    for (u32 i = 0; i < n; i++) b[i] = a[i] > 3 ? (u32)mask : 0;
    // `acc = acc op e`: an operator after a cast is binary, after `+` unary.
    for (u32 i = 0; i < n; i++) sacc = sacc + (i32)-c[i];
    for (u32 i = 0; i < n; i++) sacc = sacc + -c[i];
    for (u32 i = 0; i < n; i++) acc = acc * 3 + a[i];
    // `break` is inside an inner loop or switch when the `{` it sits in is
    // the first after a `for`, `while` or `switch`, braced or not.
    for (u32 i = 0; i < n; i++) { u32 t = 0; for (u32 j = 0; j < 4; j++) t += j; if (t > 50) { break; } b[i] = t; }
    for (u32 i = 0; i < n; i++) { if (a[i] > 3) break; b[i] = 1; }
    for (u32 i = 0; i < n; i++) { switch (a[i]) { case 1: b[i] = 2; break; default: b[i] = 3; } }
    // Every name token is a use: a member's name, an annotation's word.
    for (u32 i = 0; i < n; i++) { acc += a[i]; b[i] = gs.acc; }
    for (u32 i = 0; i < n; i++) { serial += a[i]; for (u32 j = 0; j < 2; j++) : serial { b[j] = 0; } }
    // min and max: the two expressions spelt alike.
    for (u32 i = 0; i < n; i++) if (a[i] + 16 < m) m = a[i] + 16;
    for (u32 i = 0; i < n; i++) if (a[i] + 16 < m) m = a[i] + 0x10;
    for (u32 i = 0; i < n; i++) if (acc2 < (a[i])) acc2 = (a[i]);
    // A running total becomes a scan.
    for (u32 i = 0; i < n; i++) { acc2 += a[i]; b[i] = acc2; }
    // #415 and #416.
    for (u32 i = 0; i < n; i++) { b[i] = 1; i++; }
    for (u32 i = 0; i < total; i++) total += a[i] & 1;
    for (u32 i = 0; i < b[0]; i++) b[i] = 0;
    // Grid nests, and the levels they may take.
    for (u32 y = 0; y < 300; y++) for (u32 x = 0; x < 300; x++) g2[y * 300 + x] = x + y;
    for (u32 y = 0; y < 300; y++) for (u32 x = 0; x < 300; x++) { g2[y * 300 + x] = 1; x++; }
    // Small loops: a constant count under 65536, no call.
    for (u32 i = 0; i < 100; i++) b[i] = i;
    for (u32 i = 0; i < 100; i++) b[i] = f1(i);
    // A float sum under an explicit speed goal.
    for (u32 i = 0; i < n; i++) : goal(speed) fs += fa[i];
    // Counted `while` loops, alone and inside a loop the scan reads.
    u32 v = 0;
    while (v < n) { b[v] = 2; ++v; }
    v = 0;
    while (v < n) { v++; b[0] = 1; }
    u32 lim = 10;
    while (v < lim) { lim = lim + 1; v += 1; }
    for (u32 r = 0; r < 3; r++) { u32 w = 0; while (w < n) { b[w] = r; w = w + 1; } q = r; }
    for (u32 r = 0; r < 3; r++) { u32 w2 = 0; if (r > 0) while (w2 < n) { b[w2] = r; w2++; } q = r + w2; }
    // An annotation the parser does not know still ends the header.
    for (u32 i = 0; i < n; i++) : Unroll b[i] = b[i] + 1;
    // A written par block in a loop.
    for (u32 r = 0; r < 3; r++) { par :reduce(+ acc) { for (u32 i in 0..4096) acc = acc + a[i]; } }
    K* k = new K();
    k.run();
    Stdio.printf("%u %u %u %d %u %u %u %u\n", acc, acc2, m, sacc, serial, total, q, b[5]);
    return 0;
}
XC

EXPECTED=tests/par/auto-check.expected
fail=0
: > "$W/got"
for src in "$W/headers.xc" "$W/recog.xc"; do
    name=$(basename "$src" .xc)
    if ! XC_PAR_AUTO_TRACE=1 "$XC" -q -H . -A x86_64 -O2 -S -o "$W/$name.on.s" "$src" > "$W/$name.err" 2>&1; then
        echo "FAIL $name: does not build"; sed 's/^/    /' "$W/$name.err" | head -5
        fail=1; continue
    fi
    grep '^par-auto-trace: ' "$W/$name.err" >> "$W/got"
    "$XC" -q -H . -A x86_64 -O2 -S -o "$W/$name.off.s" "$src" > /dev/null 2>&1
    cmp -s "$W/$name.on.s" "$W/$name.off.s" || { echo "FAIL $name: the trace changed the assembly"; fail=1; }
done
if [ "${UPDATE:-0}" = 1 ]; then
    cp "$W/got" "$EXPECTED"
    echo "auto-check: wrote $EXPECTED ($(wc -l < "$EXPECTED") loops)"
elif ! cmp -s "$W/got" "$EXPECTED"; then
    echo "FAIL auto-check: the verdicts differ from $EXPECTED:"
    diff "$EXPECTED" "$W/got" | head -40
    fail=1
fi
echo "--- par auto-check: $(wc -l < "$W/got") loops, $(grep -c ' lifted ' "$W/got") lifted ---"
[ $fail = 0 ]
