#!/bin/bash
# bounds-light.sh — -fbounds-check=light: a build that stops at an
# out-of-range subscript (status 134, naming the bounds), where a plain build
# and -fno-bounds-check run on. The light build keeps leaf methods frameless
# on arm64: frames are kept only for -fbounds-check's backtracing reporter,
# which method_call paid 1.40x for when the light checks borrowed its rule.
#
#   bash tests/driver/bounds-light.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/b.xc" <<'XC'
#import "Stdio.xc"
u32 a[8];
class Shape
    {
    u32 _v;
    u32 score(u32 k) { return _v ^ k; }
    }
class Box : Shape
    {
    u32 score(u32 k) { return _v + k; }
    }
i32 main(i32 argc, u8** argv)
    {
    Shape* b = argc > 5 ? new Shape() : (Shape*)new Box();
    u32 k = (u32)argc + (u32)9;
    a[k] = b.score((u32)1);
    Stdio.printf("ran on %u\n", k);
    return 0;
    }
XC
for XC in ${XC:-bin/$PLAT/xcc-xc bin/$PLAT/xcc}; do
    [ -x "$XC" ] || continue
    "$XC" -q -O2 -fbounds-check=light -H . -o "$W/d" "$W/b.xc" > "$W/o" 2>&1 || { echo "FAIL $XC: light build"; head -3 "$W/o"; fail=1; continue; }
    "$W/d" > "$W/r" 2>&1; rc=$?
    { [ $rc = 134 ] && grep -q 'but the array holds 8 elements' "$W/r"; } \
        || { echo "FAIL $XC: light build ran past a[10] (status $rc)"; head -3 "$W/r"; fail=1; }
    for m in "" -fno-bounds-check; do
        "$XC" -q -O2 $m -H . -o "$W/n" "$W/b.xc" > "$W/o" 2>&1 || { echo "FAIL $XC: build '$m'"; fail=1; continue; }
        got=$("$W/n" 2>&1)
        [ "$got" = "ran on 10" ] || { echo "FAIL $XC: build '$m' gives '$got' (checks are opt-in)"; fail=1; }
    done
    if [ "$PLAT" = osx ]; then
        "$XC" -q -O2 -fbounds-check=light -H . -S -o "$W/d.s" "$W/b.xc" || { fail=1; continue; }
        awk '/^_Box\$score:/{f=1} f&&/^ *ret/{exit} f' "$W/d.s" | grep -q 'stp x29' \
            && { echo "FAIL $XC: the light build gives Box.score a frame"; fail=1; }
        "$XC" -q -O2 -fbounds-check -H . -S -o "$W/c.s" "$W/b.xc" || { fail=1; continue; }
        awk '/^_Box\$score:/{f=1} f&&/^ *ret/{exit} f' "$W/c.s" | grep -q 'stp x29' \
            || { echo "FAIL $XC: -fbounds-check no longer keeps Box.score's frame"; fail=1; }
    fi
done
# A check on a u32 index: inlined, the u64 parameter once took the caller's
# 32-bit value, reloaded with an 8-byte load, and Map's grow loop stopped at
# "index 0, but the array holds 64 elements". Checks are calls again, but the
# index is widened at the call, which is what this keeps.
cat > "$W/m.xc" <<'XC'
#import "Stdio.xc"
i32 main(i32 argc, u8** argv)
    {
    Map* m = new Map();
    for (u32 i = (u32)0; i < (u32)100; i = i + (u32)1)
        m.set((Hashable*)String.withU32(i), (Object*)String.withU32(i * (u32)2));
    Stdio.printf("ok %u\n", m.count());
    return 0;
    }
XC
for XC in ${XC:-bin/$PLAT/xcc-xc bin/$PLAT/xcc}; do
    [ -x "$XC" ] || continue
    "$XC" -q -O2 -fbounds-check=light -H . -o "$W/m" "$W/m.xc" > "$W/o" 2>&1 || { echo "FAIL $XC: Map build"; head -3 "$W/o"; fail=1; continue; }
    got=$("$W/m" 2>&1 | head -3)
    [ "$got" = "ok 100" ] || { echo "FAIL $XC: Map growth under checks gives '$got'"; fail=1; }
done
[ $fail = 0 ] && echo "bounds-light: ok"
exit $fail
