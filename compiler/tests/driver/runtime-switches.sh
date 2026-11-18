#!/bin/bash
# runtime-switches.sh — parts of the runtime are switched on by what the
# program does, not by how its text is spelled (#338):
#
#   the class-name table   on when a call resolves to Object.className() or
#                          Object.newInstanceOfClass(), whatever the receiver
#                          looks like (an implicit self, super, a subclass
#                          name); off for a struct field or a static method
#                          of that name, and for the spellings in a comment or
#                          a string.
#
# Both compilers. The table shows in the arm64 assembly as `_xtc_cname_`
# functions.
#
#   bash tests/driver/runtime-switches.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
bad() { echo "FAIL runtime-switches: $*"; fail=1; }
F=tests/fixtures

# ── the class-name table ────────────────────────────────────────────────────
cat > "$W/super.xc" <<'XC'
#import "Stdio.xc"
class Shape { i32 sides; }
class Square : Shape { String* up(void) { return super.className(); } }
i32 main(void) { Stdio.printf("%s\n", (new Square()).up().cString()); return 0; }
XC
cat > "$W/subnew.xc" <<'XC'
#import "Stdio.xc"
class Shape { i32 sides; }
class Square : Shape { }
i32 main(void)
    {
    Object* o = Square.newInstanceOfClass(String.withCString("Shape"));
    Stdio.printf("%s\n", o == (Object*)0 ? "null" : "made");
    return 0;
    }
XC
printf 'Square\n' > "$W/super.want"
printf 'made\n' > "$W/subnew.want"
table() {  # <compiler> <source> <want: yes|no> [<expected output file>]
    local c=$1 src=$2 want=$3 out=${4:-}
    local n
    "$c" -q -O2 -A arm64 -H . -S -o "$W/t.s" "$src" 2> "$W/t.err" || { bad "$c -S $src does not build"; return; }
    n=$(grep -cE '^_*xtc_cname_[A-Za-z0-9_]*:' "$W/t.s")
    if [ "$want" = yes ] && [ "$n" = 0 ]; then bad "$c $src: no class-name table"; fi
    if [ "$want" = no ] && [ "$n" != 0 ]; then bad "$c $src: a class-name table ($n functions)"; fi
    [ -n "$out" ] || return
    if [ "$PLAT" = osx ]; then
        "$c" -q -O2 -A arm64 -H . -o "$W/t" "$src" || { bad "$c $src does not link"; return; }
        [ "$("$W/t")" = "$(cat "$out")" ] || bad "$c $src prints '$("$W/t")'"
    fi
}
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    table "$c" $F/class_names_unrelated.xc no $F/class_names_unrelated.expected.out
    table "$c" $F/class_names.xc yes $F/class_names.expected.out
    table "$c" $F/class_names_implicit.xc yes $F/class_names_implicit.expected.out
    table "$c" "$W/super.xc" yes "$W/super.want"
    table "$c" "$W/subnew.xc" yes "$W/subnew.want"
done

[ $fail = 0 ] && echo "runtime-switches: ok"
exit $fail
