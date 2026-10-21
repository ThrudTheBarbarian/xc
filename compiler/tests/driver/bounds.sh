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
if [ "$PLAT" = osx ]; then
    for A in x86_64 win64; do
        "$XC" -q -O2 -A $A -fbounds-check -H . -o "$W/b.$A" "$W/b.xc" > "$W/$A.out" 2>&1 \
            || { echo "FAIL bounds: the checked build does not link for $A"; head -3 "$W/$A.out"; fail=1; }
    done
fi
[ $fail = 0 ] && echo "--- bounds: pass ---" || echo "--- bounds: FAIL ---"
exit $fail
