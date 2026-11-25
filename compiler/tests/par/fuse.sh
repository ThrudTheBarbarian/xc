#!/bin/bash
# fuse.sh — adjacent par blocks fused into one (#147). tests/fixtures/par_fuse.xc
# has pairs that fuse and pairs that must stay apart, one for each rule (a
# neighbour read, a reduction read, different goals, a call, different
# ranges, a name clash, two pointers that may be one array). -Wpar-auto
# says which became one block and why the others did not (fuse.expected);
# the program prints the same fused, apart (-fno-par-fuse), on the CPU and
# on the GPU. Each compiler that is built is checked, and where both are,
# their code is the same.
#
#   bash tests/par/fuse.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/par_fuse.xc
want=$(cat tests/fixtures/par_fuse.expected.out)
fail=0
built=""
for C in xcc-xc xcc; do
    XC=bin/$PLAT/$C
    [ -x "$XC" ] || continue
    "$XC" -q -O2 -H . -Wpar-auto -o "$W/f.$C" "$F" > "$W/w.$C" 2>&1 || { echo "FAIL fuse ($C): no build: $(head -c 300 "$W/w.$C")"; fail=1; continue; }
    grep -E "run as one block|run apart" "$W/w.$C" | sed 's/.*warning:[^ ]* //' > "$W/r.$C"
    diff "$W/r.$C" tests/par/fuse.expected > "$W/d.$C" || { echo "FAIL fuse ($C): -Wpar-auto says otherwise:"; cat "$W/d.$C"; fail=1; }
    "$XC" -q -O2 -H . -fno-par-fuse -Wpar-auto -o "$W/n.$C" "$F" > "$W/nw.$C" 2>&1 || { echo "FAIL fuse ($C): no -fno-par-fuse build"; fail=1; continue; }
    grep -q "run as one block" "$W/nw.$C" && { echo "FAIL fuse ($C): -fno-par-fuse fused blocks"; fail=1; }
    for m in cpu gpu; do
        for b in f n; do
            got=$( (cd "$W" && XC_PAR=$m "./$b.$C") 2>/dev/null)
            [ "$got" = "$want" ] || { echo "FAIL fuse ($C, $b, $m): '$(echo "$got" | head -3)'"; fail=1; }
        done
    done
    "$XC" -q -O2 -H . -S -o "$W/s.$C.s" "$F" > /dev/null 2>&1
    built="$built $C"
done
if [ -f "$W/s.xcc-xc.s" ] && [ -f "$W/s.xcc.s" ] && ! cmp -s "$W/s.xcc-xc.s" "$W/s.xcc.s"; then
    echo "FAIL fuse: the two builds' code differs"; fail=1
fi
[ $fail = 0 ] && echo "--- fuse: pass ($built ) ---"
exit $fail
