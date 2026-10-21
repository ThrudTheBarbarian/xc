#!/bin/bash
# bounds.sh — checked builds (-fbounds-check) on the host: in-range subscripts
# run, and an out-of-range one stops the program (status 134) naming its site,
# for a fixed-size global and for a heap array of 64 KB or more (page-aligned,
# with the second header magic, which the check used to skip on every target).
# arm64 macOS uses rt-checked's reporter; x86-64 and win64 take the checks
# from Checked.xc, which the front end imports (2026-10-21; before, those
# targets refused the flag). On a Mac the x86-64 and win64 builds are linked
# too, though not run.
#
#   bash tests/driver/bounds.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/b.xc" <<'XC'
#import "Stdio.xc"
u32 g[8];
i32 main(i32 argc, u8** argv)
    {
    u32* h = new u32[20000];
    u32 bad = (u32)argc * (u32)10000;
    h[(u32)19999] = (u32)5;
    g[(u32)7] = (u32)1;
    Stdio.printf("in range %u %u\n", h[19999], g[7]);
    if (argc == 2)
        g[bad - (u32)19992] = (u32)2;
    if (argc == 3)
        h[bad - (u32)10000] = (u32)3;
    Stdio.printf("not reached\n");
    return 0;
    }
XC
"$XC" -q -O2 -fbounds-check -H . -o "$W/b" "$W/b.xc" > "$W/b.out" 2>&1 \
    || { echo "FAIL bounds: the checked build does not build"; head -3 "$W/b.out"; exit 1; }
got=$("$W/b" < /dev/null 2>&1 | head -1)
[ "$got" = "in range 5 1" ] || { echo "FAIL bounds: in-range run gives '$got'"; fail=1; }
# The global: index 8 of 8, at line 11.
"$W/b" x < /dev/null > "$W/g.out" 2>&1; rc=$?
[ $rc = 134 ] || { echo "FAIL bounds: an out-of-range global subscript exits $rc, not 134"; fail=1; }
grep -q 'out-of-bounds access' "$W/g.out" && grep -q 'b.xc:11:' "$W/g.out" \
    || { echo "FAIL bounds: the global's report does not name b.xc:11:"; head -4 "$W/g.out"; fail=1; }
grep -q 'not reached' "$W/g.out" && { echo "FAIL bounds: the program ran past the global's bad subscript"; fail=1; }
# The heap array: 20000 u32s is 80 KB, a page-aligned block; index 20000.
"$W/b" x y < /dev/null > "$W/h.out" 2>&1; rc=$?
[ $rc = 134 ] || { echo "FAIL bounds: an out-of-range subscript of a 64 KB+ heap array exits $rc, not 134"; fail=1; }
grep -q 'b.xc:13:' "$W/h.out" || { echo "FAIL bounds: the heap array's report does not name b.xc:13:"; head -4 "$W/h.out"; fail=1; }
grep -q '20000' "$W/h.out" || { echo "FAIL bounds: the heap array's report does not give the index or the count"; head -4 "$W/h.out"; fail=1; }
# Checks that cannot fail come out (bounds-elide): `for (i in 0..N) a[i]` over
# `T a[N]` keeps no check, while the same loop run one too far keeps its own
# and stops at index N.
cat > "$W/e.xc" <<'XC'
#import "Stdio.xc"
#define N 1024
u32 a[N];
u32 fill(u32 n)
    {
    for (u32 i in 0..N)
        a[i] = i * (u32)3;
    u32 s = (u32)0;
    for (u32 i in 0..n)
        s = s + a[i];
    return s;
    }
i32 main(i32 argc, u8** argv)
    {
    Stdio.printf("%u\n", fill((u32)N + (u32)argc - (u32)1));
    return 0;
    }
XC
"$XC" -q -O2 -fbounds-check -H . -o "$W/e" "$W/e.xc" > "$W/e.b" 2>&1 || { echo "FAIL bounds: the elision program does not build"; head -3 "$W/e.b"; fail=1; }
"$XC" -q -O2 -fbounds-check -H . -S -o "$W/e.s" "$W/e.xc" > /dev/null 2>&1
n=$(awk '/^_?fill:/{f=1; next} f && /^_?[A-Za-z_][A-Za-z0-9_$]*:$/ && !/^L|^\./{exit} f' "$W/e.s" | grep -cE '(bl|call)[[:space:]]+_?_xt_check_bounds')
[ "$n" = 1 ] || { echo "FAIL bounds: fill keeps $n checks, wanted 1 (the 0..n loop's; the 0..N one elided)"; fail=1; }
[ "$("$W/e" < /dev/null 2>&1)" = "1571328" ] || { echo "FAIL bounds: the elided loop gives '$("$W/e" 2>&1 | head -1)'"; fail=1; }
"$W/e" x < /dev/null > "$W/e.out" 2>&1; rc=$?
[ $rc = 134 ] && grep -q 'e.xc:10:' "$W/e.out" || { echo "FAIL bounds: the loop one too far was not stopped at e.xc:10 (exit $rc)"; head -3 "$W/e.out"; fail=1; }
# What must NOT be elided: each of these runs one past its array, and each
# must still stop at its own line (a wrong proof deletes a real check).
cat > "$W/n.xc" <<'XC'
#import "Stdio.xc"
#define M 16
u32 a[M * M];
u32 nest(u32 rows)
    {
    u32 s = (u32)0;
    for (u32 i = (u32)0; i < rows; i++)
        for (u32 k = (u32)0; k < (u32)M; k++)
            s = s + a[i * (u32)M + k];
    return s;
    }
u32 back(u32 j)
    {
    return a[j - (u32)1];
    }
u32 heap(u32 n)
    {
    u32* h = new u32[n];
    u32 s = (u32)0;
    for (u32 i = (u32)0; i <= n; i++)
        s = s + h[i];
    return s;
    }
u32 neg(void)
    {
    u32 s = (u32)0;
    for (i32 i = -1; i < 8; i++)
        s = s + a[i];
    return s;
    }
i32 main(i32 argc, u8** argv)
    {
    u32 m = (u32)argc;
    if (m == (u32)1) Stdio.printf("%u\n", nest((u32)M) + back((u32)5));
    if (m == (u32)2) Stdio.printf("%u\n", nest((u32)M + (u32)1));
    if (m == (u32)3) Stdio.printf("%u\n", back((u32)0));
    if (m == (u32)4) Stdio.printf("%u\n", heap((u32)100));
    if (m == (u32)5) Stdio.printf("%u\n", neg());
    return 0;
    }
XC
"$XC" -q -O2 -fbounds-check -H . -o "$W/n" "$W/n.xc" > "$W/n.b" 2>&1 || { echo "FAIL bounds: the must-check program does not build"; head -3 "$W/n.b"; fail=1; }
[ "$("$W/n" < /dev/null 2>&1)" = "0" ] || { echo "FAIL bounds: the must-check program's in-range run gives '$("$W/n" 2>&1 | head -1)'"; fail=1; }
args=""
for want in 2:9 3:14 4:21 5:28; do
    args="$args x"
    case=${want%%:*}; line=${want##*:}
    "$W/n" $args < /dev/null > "$W/n$case.out" 2>&1; rc=$?
    [ $rc = 134 ] && grep -q "n.xc:$line:" "$W/n$case.out" \
        || { echo "FAIL bounds: case $case was not stopped at n.xc:$line (exit $rc)"; head -3 "$W/n$case.out"; fail=1; }
done
if [ "$PLAT" = osx ]; then
    for A in x86_64 win64; do
        "$XC" -q -O2 -A $A -fbounds-check -H . -o "$W/b.$A" "$W/b.xc" > "$W/$A.out" 2>&1 \
            || { echo "FAIL bounds: the checked build does not link for $A"; head -3 "$W/$A.out"; fail=1; }
    done
fi
[ $fail = 0 ] && echo "--- bounds: pass ---" || echo "--- bounds: FAIL ---"
exit $fail
