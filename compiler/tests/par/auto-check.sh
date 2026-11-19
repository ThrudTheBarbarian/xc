#!/bin/bash
# auto-check.sh — XC_PAR_AUTO_CHECK=flags,frame over the par fixtures and the
# programs below. flags: for each loop the --par-style=auto scan reads, the
# source facts the parser put on the loop's node (range syntax, `: serial`, a
# `: goal` of its own, a range step that is not a plain literal, literal
# bounds that descend, and the condition and step shapes the tree gives with
# its parentheses and literal spellings) must agree with what the scan saw in
# the tokens. frame: for each written par block and lifted loop, the frame
# the walk of its tree computes (captures and their types in order, globals,
# writes, uses as subscript bases and updates, exits, grid names) must be the
# frame the parser's hooks built. A line that says "differ" fails. The check
# must not change the output: the assembly is compared with it on and off.
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

cat > "$W/frames.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
#define N 100000
u32 a[N];
u32 b[N];
u32 g;
u32 hist[16];
typedef u32 f_t(u32);
u32 twice(u32 x) { return x * 2; }
void apply(block void(u32) k, u32 v) { k(v); }
class Acc
{
    u32 k;
    u32 v[N];
    void fill(void)
    {
        for (u32 i = 0; i < N; i++) v[i] = self.k + i;
        par { for (u32 i in 0..N) v[i] = k + 1; }
    }
}
class Pt
{
    u32 x;
    void init(u32 v) { x = v; }
}
i32 main(void)
{
    u32 n = N;
    u32 m = 3;
    u32 s = 0;
    u32 t = 0;
    f_t* fp = &twice;
    block u32(u32) f = block u32(u32 x) { return x + m; };
    par :reduce(+ s) {
        for (u32 i in 0..n) {
            u32 q = a[i] + m;
            s += q;
            b[i] = q * 2;
        }
    }
    par :reduce(+ hist[]) { for (u32 i = 0; i < n; i++) hist[a[i] & 15] += 1; }
    for (u32 i in 0..n) { apply(block void(u32 y) { a[y] = y * m + n; }, i); b[i] = a[i] + f(i); }
    par :grid(n / 1000, 1000) { a[par.x + par.y * (n / 1000)] = par.x + m; }
    par { for (u32 i in 0..n) { if (a[i] > m) continue; b[i] = a[i] + m; } }
    for (u32 i in 0..n) b[i] = (fp)(a[i]) + fp(i);
    for (u32 i in 0..n) { a[i] = i * m; g = 0; }
    for (u32 i = 0; i < n; i++) t += a[i] ^ b[i];
    for (u32 i in 0..n) { u32 j; for (j in 0..4) a[i] = a[i] + j; }
    for (u32 i in 0..n) { Pt p(m); b[i] = p.x + i; }
    for (u32 i in 0..n) { u32 x = a[i]; x += m; b[i] = x; a[i]++; }
    for (u32 i in 0..n) { u32 i2 = i; for (u32 k = 0; k < 2; k++) b[i2] = b[i2] + k + m; }
    Acc* acc = new Acc();
    acc.k = 2;
    acc.fill();
    Stdio.printf("%u %u %u %u %u\n", s, t, hist[3], b[7], acc.v[9]);
    return 0;
}
XC

fail=0
: > "$W/got"
: > "$W/frames"
for src in tests/fixtures/par_*.xc "$W/headers.xc" "$W/frames.xc"; do
    name=$(basename "$src" .xc)
    if ! XC_PAR_AUTO_CHECK=flags,frame "$XC" -q -H . -A x86_64 -O2 -S -o "$W/$name.on.s" "$src" > "$W/$name.err" 2>&1; then
        # A fixture that expects an error still has its frames compared.
        if grep -q 'xtc-flags:.*expect=' "$src"; then
            grep '^par-frame-check: ' "$W/$name.err" >> "$W/frames"
            continue
        fi
        echo "FAIL $name: does not build"; sed 's/^/    /' "$W/$name.err" | head -5
        fail=1; continue
    fi
    grep '^par-auto-check: ' "$W/$name.err" >> "$W/got"
    grep '^par-frame-check: ' "$W/$name.err" >> "$W/frames"
    "$XC" -q -H . -A x86_64 -O2 -S -o "$W/$name.off.s" "$src" > /dev/null 2>&1
    cmp -s "$W/$name.on.s" "$W/$name.off.s" || { echo "FAIL $name: the check changed the assembly"; fail=1; }
done
if grep -q ' differ' "$W/got"; then
    echo "FAIL auto-check: source facts and tokens disagree:"; grep ' differ' "$W/got" | head -20
    fail=1
fi
if grep -q ' differ' "$W/frames"; then
    echo "FAIL auto-check: a frame walk and its hooks disagree:"; grep ' differ' "$W/frames" | head -20
    fail=1
fi
for f in "written same" "lifted same"; do
    grep -q " $f" "$W/frames" || { echo "FAIL auto-check: no block with $f"; fail=1; }
done
# Each fact is seen set at least once, so a flag the parser stopped setting shows.
for f in range=1 serial=1 goal=1 stepbad=1 desc=1 cond=1 cond=0 step=1 step=0; do
    grep -q " $f" "$W/got" || { echo "FAIL auto-check: no loop with $f"; fail=1; }
done
echo "--- par auto-check: $(wc -l < "$W/got") loops, $(grep -c ' differ' "$W/got") differ; $(wc -l < "$W/frames") frames, $(grep -c ' differ' "$W/frames") differ ---"
[ $fail = 0 ]
