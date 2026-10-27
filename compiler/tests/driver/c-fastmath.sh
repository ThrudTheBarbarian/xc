#!/bin/bash
# c-fastmath.sh — clang's fast-math flags wherever it writes them (2026-10-26).
# Under -ffp-contract=fast clang puts `contract` on calls, phis, selects and
# compares as well as on the arithmetic. The reader skipped the flags only
# after an arithmetic opcode and crashed on the rest (perlin.c built with
# -ffp-contract=fast). A program with a float call, compare, select and a
# loop-carried float builds with it and prints the plain build's answer.
#
#   bash tests/driver/c-fastmath.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
command -v clang > /dev/null 2>&1 || { echo "c-fastmath: no clang, skipped"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/f.c" <<'C'
#include <stdio.h>
static float lerp(float t, float a, float b) { return a + t * (b - a); }
int main(void)
{
    float s = 0.0f, x = 0.25f;
    for (int i = 0; i < 1000; i++) {
        float y = lerp(x, (float)i, (float)(i + 1));
        s = s + (y > 500.0f ? y * 0.5f : y);
        x = x < 0.9f ? x + 0.001f : 0.25f;
    }
    printf("%d\n", (int)s);
    return 0;
}
C
fail=0
"$XC" -q -O2 -o "$W/plain" "$W/f.c" || { echo "FAIL: the plain build"; exit 1; }
want=$("$W/plain")
for f in -ffp-contract=fast; do
    "$XC" -q -O2 $f -o "$W/f" "$W/f.c" > "$W/out" 2>&1 || { echo "FAIL: $f does not build"; head -3 "$W/out"; fail=1; continue; }
    got=$("$W/f")
    [ "$got" = "$want" ] || { echo "FAIL: $f gives '$got', the plain build '$want'"; fail=1; }
done
[ $fail = 0 ] && echo "c-fastmath: ok ($want)"
exit $fail
