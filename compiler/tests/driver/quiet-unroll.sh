#!/bin/bash
# quiet-unroll.sh — -q silences the loop unroller's note on a loop it leaves
# alone ("loop-unroll: not unrolling a N-trip loop … left as a loop"). The
# fixture's main is large enough that the unroller declines a 3-trip loop in
# it at -O2 (arm64) and a 5-trip loop (wasm32); under -q the build's stderr is
# empty.
#
#   bash tests/driver/quiet-unroll.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
for a in arm64 wasm32; do
    "$XC" -q -O2 -A $a -H . -S -o "$W/t.$a.s" tests/fixtures/tensor_basic.xc > "$W/out.$a" 2>&1 \
        || { echo "FAIL quiet-unroll: $a does not build"; head -3 "$W/out.$a"; fail=1; continue; }
    if [ -s "$W/out.$a" ]; then
        echo "FAIL quiet-unroll: -q on $a prints:"; head -3 "$W/out.$a"; fail=1
    fi
done
[ $fail = 0 ] && echo "PASS quiet-unroll"
exit $fail
