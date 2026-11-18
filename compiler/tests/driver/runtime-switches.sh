#!/bin/bash
# runtime-switches.sh — two parts of the runtime are switched on by what the
# program does, not by how its text is spelled (#338):
#
#   the class-name table   on when a call resolves to Object.className() or
#                          Object.newInstanceOfClass(), whatever the receiver
#                          looks like (an implicit self, super, a subclass
#                          name); off for a struct field or a static method
#                          of that name, and for the spellings in a comment or
#                          a string.
#   `%@` in Stdio          (HAS_ATFMT) on when a printf-family format, or a
#                          format wrapper's, holds `%@`; off for `%@` in a
#                          comment or in a string that is not a format.
#
# Both compilers. The table shows in the arm64 assembly as `_xtc_cname_`
# functions; HAS_ATFMT shows in the xt6502 assembly, where a program built
# without it differs from the same program with `%@` respelled only in that
# string.
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

# ── `%@` in Stdio ───────────────────────────────────────────────────────────
cat > "$W/real.xc" <<'XC'
#import "Stdio.xc"
i32 main(void) { String* s = String.withCString("obj"); Stdio.printf("%@\n", s); return 0; }
XC
cat > "$W/wrapper.xc" <<'XC'
#import "Stdio.xc"
void say(string fmt, ...) { Stdio.printf(fmt, ...); }
i32 main(void) { String* s = String.withCString("obj"); say("%@\n", s); return 0; }
XC
cat > "$W/use.xc" <<'XC'
#import "Stdio.xc"
use Stdio;
i32 main(void) { String* s = String.withCString("obj"); printf("%@\n", s); return 0; }
XC
# The number of lines two builds differ by: <compiler> <source> <respelled>.
lines() {
    "$1" -q -O2 -A xt6502 -H . -S -o "$W/a.s" "$2" 2> /dev/null || { echo build; return; }
    "$1" -q -O2 -A xt6502 -H . -S -o "$W/b.s" "$3" 2> /dev/null || { echo build; return; }
    diff "$W/a.s" "$W/b.s" | grep -c '^<'
}
atfmt() {  # <compiler> <source> <want: on|off>
    local c=$1 src=$2 want=$3 n
    sed 's/%@/%_/' "$src" > "$W/respelled.xc"
    n=$(lines "$c" "$src" "$W/respelled.xc")
    case "$n" in build) bad "$c $src does not build for xt6502"; return ;; esac
    # Off: only the string's own line differs.
    if [ "$want" = off ] && [ "$n" != 1 ]; then bad "$c $src: HAS_ATFMT is on ($n lines differ)"; fi
    if [ "$want" = on ] && [ "$n" -le 1 ]; then bad "$c $src: HAS_ATFMT is off"; fi
}
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    atfmt "$c" $F/printf_at_unformatted.xc off
    atfmt "$c" "$W/real.xc" on
    atfmt "$c" "$W/wrapper.xc" on
    atfmt "$c" "$W/use.xc" on
done
[ $fail = 0 ] && echo "runtime-switches: ok"
exit $fail
