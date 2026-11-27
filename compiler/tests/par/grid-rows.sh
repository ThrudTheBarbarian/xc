#!/bin/bash
# grid-rows.sh — a par :grid block over small heap arrays is not taken for
# overlapping arrays (#776). tests/fixtures/par_grid_rows.xc multiplies a
# vector (16 KB at most, from new) by a matrix: c[par.y * n + par.x] is the
# work item (n is the grid's width) and a[par.y * kk + k] is whole rows, so
# each array's extent is known and the block runs as a block. Its output is
# the same on the CPU and the GPU as the loops run serially; the compiler no
# longer warns that c is written at an index computed from data; and where
# both compilers are built, their code is the same.
#
#   bash tests/par/grid-rows.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
F=tests/fixtures/par_grid_rows.xc
built=""
for C in xcc-xc xcc; do
    XC=bin/$PLAT/$C
    [ -x "$XC" ] || continue
    "$XC" -q -O2 -H . -o "$W/g.$C" "$F" > "$W/w.$C" 2>&1 || { echo "FAIL grid-rows ($C): no build: $(head -c 300 "$W/w.$C")"; fail=1; continue; }
    grep -q "computed from data" "$W/w.$C" && { echo "FAIL grid-rows ($C): still warns that c is written at an index computed from data"; fail=1; }
    "$XC" -q -O2 -H . --par-style=cpu -o "$W/s.$C" "$F" > /dev/null 2>&1 || { echo "FAIL grid-rows ($C): no serial build"; fail=1; continue; }
    want=$("$W/s.$C")
    for m in cpu gpu; do
        got=$(XC_PAR=$m "$W/g.$C" 2>/dev/null)
        [ -n "$got" ] && [ "$got" = "$want" ] || { echo "FAIL grid-rows ($C, $m): '$got', serial '$want'"; fail=1; }
    done
    rep=$(XC_PAR=cpu XC_PAR_REPORT=1 "$W/g.$C" 2>&1)
    echo "$rep" | grep -q "arrays overlap" && { echo "FAIL grid-rows ($C): the runtime took the arrays for overlapping"; fail=1; }
    echo "$rep" | grep -qE "par: mv: [0-9]+ items on the CPU" || { echo "FAIL grid-rows ($C): the block did not run as a block: $(echo "$rep" | grep -m1 'par: mv')"; fail=1; }
    "$XC" -q -O2 -H . -S -o "$W/$C.s" "$F" > /dev/null 2>&1
    built="$built $C"
done
if [ -f "$W/xcc-xc.s" ] && [ -f "$W/xcc.s" ] && ! cmp -s "$W/xcc-xc.s" "$W/xcc.s"; then
    echo "FAIL grid-rows: the two compilers' code differs"; fail=1
fi
[ $fail = 0 ] && echo "--- grid-rows: pass ($built ) ---"
exit $fail
