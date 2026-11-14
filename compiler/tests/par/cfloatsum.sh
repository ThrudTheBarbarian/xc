#!/bin/bash
# cfloatsum.sh — a C float sum becomes a par block only under -fgoal=speed
# (#206), as the parser's scan lifts one in xc only under an explicit speed
# goal: its partial sums reassociate across the items. Without the goal the
# loop stays serial and the outliner says why; a float product stays serial
# under either. The sums here are of small integers, exact in any order, so
# every device gives clang's answer. Skipped without clang. Self-hosted
# compiler only.
#
#   bash tests/par/cfloatsum.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang --version > /dev/null 2>&1; then
    echo "--- cfloatsum: skipped (no clang) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/fs.c" <<'C'
#include <stdio.h>
#define N (1 << 20)
float a[N], b[N];
double d[N];
int main(void)
{
    for (int i = 0; i < N; i++) { a[i] = (float)(i & 7); b[i] = 2.0f; d[i] = (double)(i & 3); }
    float sum = 0.0f;
    for (int i = 0; i < N; i++)
        sum += a[i] * b[i];
    double dsum = 0.0;
    for (int i = 0; i < N; i++)
        dsum += d[i];
    float prod = 1.0f;
    for (int i = 0; i < 64; i++)
        prod *= b[i];
    printf("%.1f %.1f %.1f\n", sum, dsum, prod);
    return 0;
}
C
clang -O2 -o "$W/fs.ref" "$W/fs.c" 2>/dev/null || { echo "FAIL cfloatsum: clang cannot build fs.c"; exit 1; }
want=$("$W/fs.ref")

# The default goal: no float reduction is a block.
XC_PAR_OUTLINE_TRACE=1 "$XC" -q -O3 --par-style=auto -H . -o "$W/def" "$W/fs.c" > "$W/def.b" 2>&1 \
    || { echo "FAIL cfloatsum: fs.c does not build"; head -3 "$W/def.b"; fail=1; }
# Blocks in main: the fill loop alone by default, the fill and the two sums
# under -fgoal=speed.
blocks() { grep -cE '^outline: main(:[0-9]+)?: outlined, a block' "$1"; }
n=$(blocks "$W/def.b")
[ "$n" = 1 ] || { echo "FAIL cfloatsum: $n loops of main became blocks without -fgoal=speed, wanted 1 (the fill)"; fail=1; }
grep -q 'a float reduction' "$W/def.b" || { echo "FAIL cfloatsum: the outliner did not say a float reduction stays serial"; fail=1; }
[ -x "$W/def" ] && { [ "$("$W/def")" = "$want" ] || { echo "FAIL cfloatsum: default build gives $("$W/def"), clang's $want"; fail=1; }; }

# -fgoal=speed: the two sums are blocks, the product is not.
XC_PAR_OUTLINE_TRACE=1 "$XC" -q -O3 --par-style=auto -fgoal=speed -H . -o "$W/spd" "$W/fs.c" > "$W/spd.b" 2>&1 \
    || { echo "FAIL cfloatsum: fs.c does not build with -fgoal=speed"; head -3 "$W/spd.b"; fail=1; }
n=$(blocks "$W/spd.b")
[ "$n" = 3 ] || { echo "FAIL cfloatsum: $n loops of main became blocks under -fgoal=speed, wanted 3 (the fill and the two sums, not the product)"; fail=1; }
if [ -x "$W/spd" ]; then
    devs="cpu auto"
    [ "$(uname -s)" = Darwin ] && devs="$devs gpu"
    for dev in $devs; do
        got=$(XC_PAR=$dev "$W/spd")
        [ "$got" = "$want" ] || { echo "FAIL cfloatsum: -fgoal=speed ($dev) gives $got, clang's $want"; fail=1; }
    done
    if [ "$(uname -s)" = Darwin ]; then
        XC_PAR=gpu XC_PAR_REPORT=1 "$W/spd" 2>&1 | grep -q 'fs.c:9: .*items on the GPU' \
            || { echo "FAIL cfloatsum: the float sum did not run on the GPU"; fail=1; }
    fi
fi
[ $fail = 0 ] && echo "--- cfloatsum: pass ---" || echo "--- cfloatsum: FAIL ---"
exit $fail
