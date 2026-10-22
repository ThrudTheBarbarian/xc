#!/bin/bash
# vec-pressure.sh — vector register pressure (2026-10-22): a loop whose body
# holds more vectors at once than there are registers used to stop the build
# ("vector register pressure exceeded"). Now the allocator gives up a value:
# a constant splat is made again where it is read (arm64 and x86), anything
# else is spilled to its frame slot (x86). Checked against clang, and on x86
# at the SSE, AVX2 and AVX-512 widths where the host has them.
#
#   bash tests/driver/vec-pressure.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
command -v clang > /dev/null || { echo "--- vec-pressure: skipped (no clang) ---"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/p.c" <<'C'
#include <stdio.h>
#define N 4096
unsigned xs[N];
int main(int argc, char **argv)
{
    for (unsigned i = 0; i < N; i++) xs[i] = i * 2654435761u + (unsigned)argc;
    unsigned total = 0;
    for (unsigned i = 0; i < N; i++) {
        unsigned x = xs[i];
        total += ((x * 653163u) ^ 274281999u) + ((x * 777823u) ^ 384974576u) + ((x * 833823u) ^ 741361656u) + ((x * 988233u) ^ 903565517u) + ((x * 775843u) ^ 700113704u) + ((x * 967131u) ^ 569125962u) + ((x * 30417u) ^ 902316928u) + ((x * 488243u) ^ 833179166u) + ((x * 989185u) ^ 267418254u) + ((x * 680503u) ^ 55677007u) + ((x * 944665u) ^ 168417828u) + ((x * 118709u) ^ 399210080u) + ((x * 491857u) ^ 932486209u) + ((x * 258553u) ^ 408835700u) + ((x * 570177u) ^ 109494178u) + ((x * 601823u) ^ 267716823u);
    }
    printf("%u\n", total);
    return 0;
}
C
clang -O2 -o "$W/p.ref" "$W/p.c" 2> /dev/null || { echo "FAIL vec-pressure: clang does not build it"; exit 1; }
want=$("$W/p.ref")
widths=""
[ "$PLAT" = linux ] && widths="-mavx2 -mavx512"
for m in "" $widths; do
    [ "$m" = -mavx512 ] && ! grep -q avx512f /proc/cpuinfo 2> /dev/null && continue
    "$XC" -q -O2 $m -H . -o "$W/p" "$W/p.c" > "$W/b" 2>&1 || { echo "FAIL vec-pressure: $m does not build"; head -2 "$W/b"; fail=1; continue; }
    got=$("$W/p")
    [ "$got" = "$want" ] || { echo "FAIL vec-pressure: $m gives $got, clang $want"; fail=1; }
done
[ $fail = 0 ] && echo "--- vec-pressure: pass ---" || { echo "--- vec-pressure: FAIL ---"; exit 1; }
