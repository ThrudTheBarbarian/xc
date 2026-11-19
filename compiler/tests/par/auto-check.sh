#!/bin/bash
# auto-check.sh — XC_PAR_AUTO_CHECK=flags over the par_auto fixtures and the
# header spellings below: for each loop the --par-style=auto scan reads, the
# source facts the parser put on the loop's node (range syntax, `: serial`, a
# `: goal` of its own, a range step that is not a plain literal, literal
# bounds that descend, and the condition and step shapes the tree gives with
# its parentheses and literal spellings) must agree with what the scan saw in
# the tokens. A line that says "differ" fails. The check must not change the
# output: the assembly is compared with it on and off.
#
#   bash tests/par/auto-check.sh                   # bin/<plat>/xcc-xc
#   XC=path/to/xcc bash tests/par/auto-check.sh
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

fail=0
: > "$W/got"
for src in tests/fixtures/par_auto_*.xc "$W/headers.xc"; do
    name=$(basename "$src" .xc)
    if ! XC_PAR_AUTO_CHECK=flags "$XC" -q -H . -A x86_64 -O2 -S -o "$W/$name.on.s" "$src" > "$W/$name.err" 2>&1; then
        echo "FAIL $name: does not build"; sed 's/^/    /' "$W/$name.err" | head -5
        fail=1; continue
    fi
    grep '^par-auto-check: ' "$W/$name.err" >> "$W/got"
    "$XC" -q -H . -A x86_64 -O2 -S -o "$W/$name.off.s" "$src" > /dev/null 2>&1
    cmp -s "$W/$name.on.s" "$W/$name.off.s" || { echo "FAIL $name: the check changed the assembly"; fail=1; }
done
if grep -q ' differ' "$W/got"; then
    echo "FAIL auto-check: source facts and tokens disagree:"; grep ' differ' "$W/got" | head -20
    fail=1
fi
# Each fact is seen set at least once, so a flag the parser stopped setting shows.
for f in range=1 serial=1 goal=1 stepbad=1 desc=1 cond=1 cond=0 step=1 step=0; do
    grep -q " $f" "$W/got" || { echo "FAIL auto-check: no loop with $f"; fail=1; }
done
echo "--- par auto-check: $(wc -l < "$W/got") loops, $(grep -c ' differ' "$W/got") differ ---"
[ $fail = 0 ]
