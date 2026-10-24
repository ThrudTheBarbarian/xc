#!/bin/bash
# split-iface.sh — files compiled one at a time against each other's
# interfaces, as selfhost/tools/split-build.sh builds the compiler
# (2026-10-24). Two shapes the reference refused, so it could not split-build:
#
#   a twice  c imports a and b, and b's interface carries a's enum as well:
#            "Duplicate enum name 'Shade'".
#   opaque   e imports b only, whose interface names a's class behind a
#            pointer: "imported library names the type 'Box'".
#
# Each compiler builds the interfaces and objects, links a, b and c, and the
# program prints its answer.
#
#   bash tests/crossmod/split-iface.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
A=$( [ "$(uname -m)" = arm64 ] && echo arm64 || echo x86_64 )
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/src"
cat > "$W/src/a.xc" <<'XC'
#import "Stdio.xc"
enum Shade = { shDark = 0, shLight = 1 };
class Box : Object
    {
    u32 v;
    u32 twice(void) { return v * (u32)2; }
    }
Box* makeBox(u32 v) { Box* b = new Box(); b.v = v; return b; }
XC
cat > "$W/src/b.xc" <<'XC'
#import <a>
class Holder : Object
    {
    Box* box;
    u16 shade;
    u32 value(void) { return shade == (u16)shLight ? box.twice() : box.v; }
    }
Holder* holding(Box* b, u16 s) { Holder* h = new Holder(); h.box = b; h.shade = s; return h; }
XC
cat > "$W/src/c.xc" <<'XC'
#import <a>
#import <b>
#import "Stdio.xc"
i32 main(void)
    {
    Holder* h = holding(makeBox((u32)21), (u16)shLight);
    Stdio.printf("%u %u\n", h.value(), (u32)shDark);
    return 0;
    }
XC
cat > "$W/src/e.xc" <<'XC'
#import <b>
u32 valueOf(Holder* h) { return h.value(); }
XC
for XC in ${XC:-bin/$PLAT/xcc bin/$PLAT/xcc-xc}; do
    [ -x "$XC" ] || continue
    d="$W/$(basename "$XC")"; mkdir -p "$d/if" "$d/obj"
    ok=1
    for f in a b c e; do
        "$XC" -q -A $A -H . -L "$d/if" --emit-iface -o "$d/if/$f.xtc.iface" "$W/src/$f.xc" > "$d/if/$f.log" 2>&1 \
            || { echo "FAIL $XC: the interface of $f"; head -3 "$d/if/$f.log"; ok=0; }
    done
    for f in a b c e; do
        [ $ok = 1 ] || break
        "$XC" -q -O2 -A $A -H . -L "$d/if" -c -o "$d/obj/$f.o" "$W/src/$f.xc" > "$d/obj/$f.log" 2>&1 \
            || { echo "FAIL $XC: the object of $f"; sed 's/\x1b\[[0-9;]*m//g' "$d/obj/$f.log" | head -3; ok=0; }
    done
    if [ $ok = 1 ]; then
        "$XC" -q -A $A -H . -o "$d/p" "$d/obj/a.o" "$d/obj/b.o" "$d/obj/c.o" > "$d/link.log" 2>&1 \
            || { echo "FAIL $XC: the link"; head -3 "$d/link.log"; ok=0; }
    fi
    if [ $ok = 1 ]; then
        got=$("$d/p")
        [ "$got" = "42 0" ] || { echo "FAIL $XC: the program gives '$got'"; ok=0; }
    fi
    [ $ok = 1 ] || fail=1
done
[ $fail = 0 ] && echo "split-iface: ok"
exit $fail
