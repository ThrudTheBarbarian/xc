#!/bin/bash
# par-self-fields.sh — a par body reads self's fields (0.9.3).
#
# A loop in a method that reads `self.n` or `self.v[i]` used to be refused by
# the block form ("cannot capture 'self'"), so default lifting kept it as the
# loop. `self.f` for the class's own ivar now means what a bare `f` means in
# a par body: a capture of its value.
#
#   1. Reads of self's fields (bound, array, scalar): the loop is lifted, and
#      prints what --par-style=cpu prints.
#   2. A call on self in the loop: not lifted (methods are not run in
#      parallel automatically), same answer.
#   3. A local of the field's name: self.n is left alone, same answer.
#   4. A write to self's field in the loop: not lifted, same answer.
#   5. An explicit par block reading self's fields builds and runs, one of
#      them the second name of a comma-list declaration (`float scale, bias;`).
#
# Both compilers, the same warnings and output from each.
#
#   bash tests/driver/par-self-fields.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD
PLAT=$([ "$(uname -s)" = Darwin ] && echo osx || echo linux)
REF=${REF:-bin/$PLAT/xcc}; XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d /tmp/par-self-fields.XXXX)
trap 'rm -rf "$W"' EXIT
fail=0

cat > "$W/f.xc" <<'EOF'
#import "Stdio.xc"
class Box : Object
{
    u32 n;
    i64* v;
    i64 k;
    i64 weight(u32 i) { return (i64)i & (i64)3; }
    i64 sumFields(void)
    {
        i64 t = 0;
        for (u32 i = 0; i < self.n; i = i + 1)
            t = t + self.v[i] * self.k;
        return t;
    }
    i64 sumCalls(void)
    {
        i64 t = 0;
        for (u32 i = 0; i < self.n; i = i + 1)
            t = t + self.weight(i);
        return t;
    }
    i64 sumShadow(u32 n)
    {
        i64 t = 0;
        for (u32 i = 0; i < n; i = i + 1)
            t = t + self.v[i] + (i64)self.n;
        return t;
    }
    void bumpK(void)
    {
        for (u32 i = 0; i < self.n; i = i + 1)
            self.k = self.k + (i64)1;
    }
    void fill(void)
    {
        for (u32 i = 0; i < self.n; i = i + 1)
            self.v[i] = (i64)i * self.k;
    }
}
i32 main(void)
{
    Box* b = new Box();
    b.n = 200000;
    b.k = 3;
    b.v = new i64[200000];
    b.fill();
    Stdio.printf("%ld %ld %ld\n", b.sumFields(), b.sumCalls(), b.sumShadow((u32)1000));
    b.bumpK();
    Stdio.printf("%ld\n", b.k);
    return 0;
}
EOF
cat > "$W/p.xc" <<'EOF'
#import "Stdio.xc"
#import "Par.xc"
class Grid : Object
{
    u32 n;
    float* a;
    float scale, bias;
    void run(void)
    {
        par { for (u32 i in 0..self.n) { self.a[i] = (float)(i) * self.scale + self.bias; } }
    }
}
i32 main(void)
{
    Grid* g = new Grid();
    g.n = 100000;
    g.scale = 0.5;
    g.bias = 1.0;
    g.a = new float[100000];
    g.run();
    Stdio.printf("%.1f %.1f\n", (double)(g.a[3]), (double)(g.a[99999]));
    return 0;
}
EOF

for c in "$REF" "$XC"; do
    cn=$(basename "$c")
    "$c" -H "$ROOT" -q -O2 --par-style=cpu -o "$W/cpu" "$W/f.xc" || { echo "FAIL $cn: f.xc does not build at --par-style=cpu"; fail=1; continue; }
    "$c" -H "$ROOT" -q -O2 -Wpar-auto -o "$W/auto" "$W/f.xc" 2> "$W/warn" || { echo "FAIL $cn: f.xc does not build at the default"; cat "$W/warn" | head -5; fail=1; continue; }
    want=$(XC_PAR=cpu "$W/cpu"); got=$("$W/auto")
    [ "$want" = "$got" ] || { echo "FAIL $cn: default prints '$got', --par-style=cpu '$want'"; fail=1; }
    lifted=$(grep -c 'became a .par. block' "$W/warn")
    line=$(grep -n 'self.v\[i\] \* self.k' "$W/f.xc" | cut -d: -f1); line=$((line - 1))
    grep -q "f.xc:$line:.*became a 'par' block" "$W/warn" || { echo "FAIL $cn: sumFields's loop (line $line) was not lifted"; fail=1; }
    for m in sumCalls bumpK; do
        l=$(grep -n "i64 $m\|void $m" "$W/f.xc" | cut -d: -f1); l=$((l + 3))
        grep -q "f.xc:$l:.*became a 'par' block" "$W/warn" && { echo "FAIL $cn: $m's loop (line $l) was lifted"; fail=1; }
    done
    "$c" -H "$ROOT" -q -O2 -o "$W/p" "$W/p.xc" 2> "$W/perr" || { echo "FAIL $cn: an explicit par block reading self's fields does not build:"; head -3 "$W/perr"; fail=1; continue; }
    [ "$("$W/p")" = "2.5 50000.5" ] || { echo "FAIL $cn: the explicit par block printed '$("$W/p")'"; fail=1; }
    grep 'warning:' "$W/warn" | sed $'s/\x1b\\[[0-9;]*m//g' > "$W/warn.$cn"   # the warning lines (the reference also prints the source line)
done
cmp -s "$W/warn.$(basename "$REF")" "$W/warn.$(basename "$XC")" 2>/dev/null || { echo "FAIL: the two compilers' -Wpar-auto warnings differ"; fail=1; }
[ $fail = 0 ] && echo "par-self-fields: ok"
exit $fail
