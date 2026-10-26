#!/bin/bash
# ir-input.sh — xcc compiles IR text (2026-10-26): what --emit-ir writes,
# fed back, gives the same code as the source it came from, for arm64 and
# x86-64, and the program built from it runs. Before, any input was read as xc
# source ("Expected 'identifier'" at `module "..."`).
#
#   bash tests/driver/ir-input.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
F=tests/fixtures/dead_store.xc
for a in arm64 x86_64; do
    "$XC" -q -A $a -O2 -H . --emit-ir -S -o "$W/src.$a.s" $F 2> "$W/m.$a.ir" || { echo "FAIL ir-input: $a source"; fail=1; continue; }
    "$XC" -q -A $a -O2 -H . -S -o "$W/ir.$a.s" "$W/m.$a.ir" || { echo "FAIL ir-input: $a IR not compiled"; fail=1; continue; }
    cmp -s "$W/src.$a.s" "$W/ir.$a.s" || { echo "FAIL ir-input: $a code from IR differs from the source's"; fail=1; }
done
"$XC" -q -O2 -H . --emit-ir -o "$W/x" $F 2> "$W/m.ir"
if "$XC" -q -O2 -H . -o "$W/p" "$W/m.ir"; then
    got=$("$W/p")
    [ "$got" = "$(cat tests/fixtures/dead_store.expected.out)" ] || { echo "FAIL ir-input: the program from IR printed '$got'"; fail=1; }
else
    echo "FAIL ir-input: no program from IR"; fail=1
fi
[ $fail = 0 ] && echo "ir-input: ok"
exit $fail
