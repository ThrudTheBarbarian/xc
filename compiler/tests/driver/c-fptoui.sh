#!/bin/bash
# c-fptoui.sh — C's float-to-integer casts are unchecked (2026-10-25). xc's
# FpToSI / FpToUI give 0 for a NaN or a value the destination cannot hold,
# which costs x86-64 five instructions a conversion; C leaves those cases
# undefined, so the C reader marks its casts `unchecked` and the back end
# emits the conversion alone, as GCC and clang do (perlin converts twice an
# octave). Checks: the answers (unsigned values from 2^31 up included), the
# six marks in the IR, the reference keeping them through its -O2 passes
# (the inliner and the loop passes once copied a predicate for compares
# only), and no range check in either compiler's x86-64 to_u32.
#
#   bash tests/driver/c-fptoui.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
CG=bin/$PLAT/xcc-cg-x86_64
command -v clang > /dev/null || { echo "--- c-fptoui: skipped (no clang) ---"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
want="3000000000 7 4294967295 -2 2147483520 65535 -9000000000000000 18000000000000000000 12"
"$XC" -q -O2 -o "$W/f" tests/c/fptoui.c || { echo "FAIL c-fptoui: does not build"; exit 1; }
got=$("$W/f")
[ "$got" = "$want" ] || { echo "FAIL c-fptoui: printed '$got'"; fail=1; }
"$XC" -q -A x86_64 -O2 --emit-ir -o "$W/x" tests/c/fptoui.c 2> "$W/c.ir"
n=$(grep -c -E 'FpTo(SI|UI) unchecked' "$W/c.ir")
[ "$n" = 6 ] || { echo "FAIL c-fptoui: $n conversions marked unchecked, want 6"; fail=1; }
# A function's x86-64 body: no compare or cmov between its conversion and ret.
checked() { awk '/<to_u32>:|^_?to_u32:/,/ret/' "$1" | grep -c -E 'cmov|cmp[[:space:]]+rax'; }
if [ -x "$CG" ]; then
    k=$("$CG" -O2 -q --dump-opt-ir "$W/c.ir" 2>&1 | grep -c 'unchecked')
    # Six, and more once main's calls are inlined (each copy keeps its mark).
    [ "$k" -ge 6 ] || { echo "FAIL c-fptoui: the reference's -O2 kept $k marks, want 6 or more"; fail=1; }
    "$CG" -O2 -q -o "$W/ref.s" "$W/c.ir"
    [ "$(checked "$W/ref.s")" = 0 ] || { echo "FAIL c-fptoui: the reference's to_u32 checks its result"; fail=1; }
fi
"$XC" -q -A x86_64 -O2 -static -o "$W/f86" tests/c/fptoui.c
objdump -d --no-show-raw-insn -M intel "$W/f86" > "$W/f86.dis" 2> /dev/null
[ "$(checked "$W/f86.dis")" = 0 ] || { echo "FAIL c-fptoui: the port's to_u32 checks its result"; fail=1; }
# -S writes xcc's part as assembly where asked (it went to a scratch object).
"$XC" -q -A x86_64 -O2 -S -o "$W/f86.s" tests/c/fptoui.c
if [ ! -s "$W/f86.s" ] || ! grep -q -E '^_?to_u32:' "$W/f86.s"; then
    echo "FAIL c-fptoui: -S wrote no assembly"; fail=1
elif [ "$(checked "$W/f86.s")" != 0 ]; then
    echo "FAIL c-fptoui: the port's -S to_u32 checks its result"; fail=1
fi
# arm64: the conversion alone, without the fit check's csel (both compilers).
"$XC" -q -A arm64 -O2 -S -o "$W/a64.s" tests/c/fptoui.c
if [ "$(awk '/^_?to_u32:/,/ret/' "$W/a64.s" | grep -c 'csel')" != 0 ]; then
    echo "FAIL c-fptoui: the port's arm64 to_u32 checks its result"; fail=1
fi
CG64=bin/$PLAT/xcc-cg-arm64
if [ -x "$CG64" ]; then
    "$XC" -q -A arm64 -O2 --emit-ir -o "$W/x64" tests/c/fptoui.c 2> "$W/c64.ir"
    "$CG64" -O2 -q -o "$W/ref64.s" "$W/c64.ir"
    [ "$(awk '/^_?to_u32:/,/ret/' "$W/ref64.s" | grep -c 'csel')" = 0 ] \
        || { echo "FAIL c-fptoui: the reference's arm64 to_u32 checks its result"; fail=1; }
fi
[ $fail = 0 ] && echo "c-fptoui: ok"
exit $fail
