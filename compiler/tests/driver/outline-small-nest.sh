#!/bin/bash
# outline-small-nest.sh — --par-style=auto leaves a nest of small constant
# loops in place (its work, the product of the trips, is under PP_MIN_TRIP),
# and still makes a block of a nest whose outer loop is large: a 4x4 nest run
# 2000 times is no block, a 1M x 4 nest is one. The program prints the same
# values as clang's build. Self-hosted compiler only (the IR outliner).
#
#   bash tests/driver/outline-small-nest.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$([ "$(uname -s)" = Darwin ] && echo osx || echo linux)
XC=${XC:-bin/$PLAT/xcc-xc}
command -v clang > /dev/null || { echo "outline-small-nest: no clang, skipped"; exit 0; }
W=$(mktemp -d /tmp/olnest.XXXX)
trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/n.c" <<'XEOF'
#include <stdio.h>
static float m[16], big[1 << 20];
int main(void) {
    float acc = 0.0f;
    for (int r = 0; r < 2000; r++) {
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++)
                m[i * 4 + j] = (float)(i * j + r);
        acc += m[5];
    }
    for (int i = 0; i < (1 << 20); i++)
        for (int k = 0; k < 4; k++)
            big[i] = big[i] + (float)(i + k);
    printf("%f %f\n", acc, big[1000]);
    return 0;
}
XEOF
XC_PAR_OUTLINE_TRACE=1 "$XC" -q -O3 --par-style=auto -H . -o "$W/n" "$W/n.c" > "$W/log" 2>&1 || { echo "FAIL build"; head -5 "$W/log"; exit 1; }
grep -q 'main:6: not a block: a constant trip below PP_MIN_TRIP' "$W/log" || { echo "FAIL the 4x4 nest (line 6) is not left in place"; cat "$W/log"; fail=1; }
grep -q 'main:6: outlined' "$W/log" && { echo "FAIL the 4x4 nest (line 6) was outlined"; fail=1; }
grep -q 'main:11: outlined, a block' "$W/log" || { echo "FAIL the 1M x 4 nest (line 11) is not a block"; cat "$W/log"; fail=1; }
clang -O2 -o "$W/c" "$W/n.c" 2> /dev/null && [ "$("$W/n")" = "$("$W/c")" ] || { echo "FAIL output differs from clang's"; fail=1; }
[ $fail = 0 ] && echo "outline-small-nest: ok"
exit $fail
