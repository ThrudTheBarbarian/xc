#!/bin/bash
# m68k-far-field.sh — a struct field past 32 KB is reached at its own offset
# (#289). A 68000 d16 displacement reaches 32767 bytes; the code generator
# folded any field offset into one and the assembler masked it, so
# `40000(a0)` was `-25536(a0)` and the store landed 25 KB below the object.
# The code generator now moves a0 to such a field first, and the assembler
# refuses a d16 that does not fit. The program writes the field through the
# struct and reads it back through the field and a raw pointer: exit 42 when
# both agree, in the 68000 simulator, with both compilers.
#
#   bash tests/driver/m68k-far-field.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
SIM=bin/$PLAT/xcc-sim-68k
[ -x "$SIM" ] || { echo "m68k-far-field: no 68000 simulator, skipped"; exit 0; }
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/far.xc" <<'XC'
struct Big
    {
    u8 pad[40000];
    i32 x;
    }
Big g;
i32 main(void)
    {
    g.x = (i32)77;
    u8* p = (u8*)&g;
    i32 raw = *(i32*)(p + 40000);
    if (g.x == (i32)77 && raw == (i32)77)
        return 42;
    return 1;
    }
XC
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    for o in -O0 -O2; do
        "$c" -q $o -A m68k -H . -o "$W/far.prg" "$W/far.xc" > "$W/e" 2>&1 || { echo "FAIL $(basename "$c") $o: no build: $(head -c 300 "$W/e")"; fail=1; continue; }
        "$SIM" "$W/far.prg" > /dev/null 2>&1 && got=0 || got=$?
        [ "$got" = 42 ] || { echo "FAIL $(basename "$c") $o: exit $got, want 42 (the field and the raw pointer disagree)"; fail=1; }
    done
done
[ $fail = 0 ] && echo "m68k-far-field: ok"
exit $fail
