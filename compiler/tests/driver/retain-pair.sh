#!/bin/bash
# retain-pair.sh — a Retain and a Release of the same value with only pure
# instructions between cancel (2026-10-25). An Array search retained and
# released every element around one compare: hasVal's loop must hold no
# Retain now, and retain_pair.xc (whose pairs across a call must stay) gives
# its answer from both compilers at -O0 and -O2.
#
#   bash tests/driver/retain-pair.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
"$XC" -q -O2 -H . --emit-ir-opt -o "$W/r" tests/fixtures/retain_pair.xc 2> "$W/r.ir"
n=$(awk '/function hasVal\(/,/^  }/' "$W/r.ir" | grep -c ' = Retain ')
[ "$n" = 0 ] || { echo "FAIL retain-pair: hasVal still retains ($n)"; fail=1; }
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    for o in O0 O2; do
        "$c" -q -$o -H . -o "$W/r" tests/fixtures/retain_pair.xc || { echo "FAIL retain-pair: $c -$o does not build"; fail=1; continue; }
        got=$("$W/r")
        [ "$got" = "$(cat tests/fixtures/retain_pair.expected.out)" ] || { echo "FAIL retain-pair: $c -$o gives '$got'"; fail=1; }
    done
done
[ $fail = 0 ] && echo "retain-pair: ok"
exit $fail
