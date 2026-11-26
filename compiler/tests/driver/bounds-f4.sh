#!/bin/bash
# bounds-f4.sh — checked builds (-fbounds-check) of f4 arrays count elements,
# not bytes. For an odd n, ceil(n / 2) bytes hold n elements, so index n is
# inside the last byte but past the array: the check stops it (status 134,
# naming the site), for a fixed-size global and for a heap array from
# new f4[n], whose header records n. Index n - 1 runs.
#
#   bash tests/driver/bounds-f4.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/b.xc" <<'XC'
#import "Stdio.xc"
f4 g[7];
i32 main(i32 argc, u8** argv)
    {
    u32 n = (u32)argc * (u32)9;
    f4[] h = new f4[n];
    u32 last = n - (u32)1;
    h[last] = 1.5;
    g[(u32)6] = -2.0;
    Stdio.printf("in range %f %f %u %u\n", h[last], g[6], (u32)h.length, (u32)g.length);
    if (argc == 2)
        g[last - (u32)10] = 3.0;
    if (argc == 3)
        h[n / (u32)3] = 3.0;
    Stdio.printf("not reached\n");
    return 0;
    }
XC
"$XC" -q --par-style=cpu -O2 -fbounds-check -H . -o "$W/b" "$W/b.xc" > "$W/b.out" 2>&1 \
    || { echo "FAIL bounds-f4: the checked build does not build"; head -3 "$W/b.out"; exit 1; }
got=$("$W/b" < /dev/null 2>&1 | head -1)
[ "$got" = "in range 1.500000 -2.000000 9 7" ] || { echo "FAIL bounds-f4: in-range run gives '$got'"; fail=1; }
# The global: one argument gives n = 18 and index 17 - 10 = 7 of g[7], in the
# unused nibble of its last byte.
"$W/b" x < /dev/null > "$W/g.out" 2>&1; rc=$?
[ $rc = 134 ] || { echo "FAIL bounds-f4: an out-of-range f4 global subscript exits $rc, not 134"; fail=1; }
grep -q 'b.xc:12:' "$W/g.out" || { echo "FAIL bounds-f4: the global's report does not name b.xc:12:"; head -4 "$W/g.out"; fail=1; }
# The heap array: argc 3 gives n = 27 elements in 14 bytes; index n / 3 = 9
# is in range, so this run must reach the end.
"$W/b" x y < /dev/null > "$W/h.out" 2>&1; rc=$?
[ $rc = 0 ] && grep -q 'not reached' "$W/h.out" || { echo "FAIL bounds-f4: an in-range f4 heap subscript stopped ($rc)"; head -4 "$W/h.out"; fail=1; }
# Index n of an odd n, in the last byte's unused nibble: caught.
cat > "$W/o.xc" <<'XC'
#import "Stdio.xc"
f4 g[7];
i32 main(i32 argc, u8** argv)
    {
    u32 n = (u32)argc * (u32)9;
    f4[] h = new f4[n];
    u32 at = n - (u32)1 + (u32)argc / (u32)2;
    h[at] = 1.0;
    g[at - (u32)2] = 2.0;
    Stdio.printf("ok %f %f\n", h[at], g[at - (u32)2]);
    return 0;
    }
XC
"$XC" -q --par-style=cpu -O2 -fbounds-check -H . -o "$W/o" "$W/o.xc" > "$W/o.b" 2>&1 \
    || { echo "FAIL bounds-f4: the second program does not build"; head -3 "$W/o.b"; exit 1; }
got=$("$W/o" < /dev/null 2>&1 | head -1)
[ "$got" = "ok 1.000000 2.000000" ] || { echo "FAIL bounds-f4: index n - 1 of 9 gives '$got'"; fail=1; }
# Two arguments: n = 27, at = 27 (index n of an odd n), in byte 13 of 14.
"$W/o" x y < /dev/null > "$W/o.out" 2>&1; rc=$?
[ $rc = 134 ] || { echo "FAIL bounds-f4: index n of an f4[n] (n = 27) exits $rc, not 134"; fail=1; }
grep -q 'o.xc:8:' "$W/o.out" || { echo "FAIL bounds-f4: the heap report does not name o.xc:8:"; head -4 "$W/o.out"; fail=1; }
grep -q '27' "$W/o.out" || { echo "FAIL bounds-f4: the heap report does not give the index or the count"; head -4 "$W/o.out"; fail=1; }
[ $fail = 0 ] && echo "--- bounds-f4: ok ---"
exit $fail
