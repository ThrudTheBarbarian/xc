#!/bin/bash
# licm-all-loops.sh — LICM visits every loop in a round (#334). It moved one
# loop's invariants per round under a cap of 32 rounds, so in a function with
# forty such loops the last eight kept their invariant products inside, and
# XC_OPT_CAPS=1 said "LICM stopped at its round cap (32)". Checked: neither
# compiler reports the cap on tests/fixtures/licm_many_loops.xc, and the
# program prints the fixture's answer.
#
#   bash tests/driver/licm-all-loops.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
REF=bin/$PLAT/xcc
F=tests/fixtures/licm_many_loops.xc
[ -x "$XC" ] || { echo "FAIL licm-all-loops: no compiler at $XC"; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
want=$(cat tests/fixtures/licm_many_loops.expected.out)
for c in "$XC" "$REF"; do
    [ -x "$c" ] || continue
    XC_OPT_CAPS=1 "$c" -q -O2 -H . -o "$W/p" "$F" > "$W/out" 2>&1 \
        || { echo "FAIL licm-all-loops: $c does not build the fixture"; tail -3 "$W/out"; fail=1; continue; }
    if grep -q "LICM stopped at its round cap" "$W/out"; then
        echo "FAIL licm-all-loops: $c: $(grep -m1 'LICM stopped' "$W/out")"; fail=1
    fi
    got=$("$W/p")
    [ "$got" = "$want" ] || { echo "FAIL licm-all-loops: $c's program printed '$got', want '$want'"; fail=1; }
done
[ $fail = 0 ] && echo "licm-all-loops: ok"
exit $fail
