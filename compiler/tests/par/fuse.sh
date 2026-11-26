#!/bin/bash
# fuse.sh — adjacent par blocks fused into one (#147). tests/fixtures/par_fuse.xc
# has written blocks that fuse and pairs that must stay apart, one for each
# rule (a neighbour read, a reduction read, different goals, a call,
# different ranges, a name clash, two pointers that may be one array);
# par_fuse_auto.xc the same for loops --par-style=auto lifts; par_fuse_scalar.xc
# an intermediate array kept in a register, and arrays that stay arrays. -Wpar-auto
# says which became one block and why the others did not (fuse.expected,
# fuse-auto.expected); each program prints the same fused, apart
# (-fno-par-fuse), on the CPU and on the GPU. Each compiler that is built
# is checked, and where both are, their code is the same.
#
#   bash tests/par/fuse.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
built=""
for K in par_fuse:fuse par_fuse_auto:fuse-auto par_fuse_scalar:fuse-scalar; do
F=tests/fixtures/${K%%:*}.xc
EXP=tests/par/${K#*:}.expected
K=${K%%:*}
want=$(cat "${F%.xc}.expected.out")
built=""
for C in xcc-xc xcc; do
    XC=bin/$PLAT/$C
    [ -x "$XC" ] || continue
    "$XC" -q -O2 -H . -Wpar-auto -o "$W/f.$C" "$F" > "$W/w.$C" 2>&1 || { echo "FAIL fuse ($K, $C): no build: $(head -c 300 "$W/w.$C")"; fail=1; continue; }
    grep -E "run as one block|run apart|in a register" "$W/w.$C" | sed 's/.*warning:[^ ]* //' > "$W/r.$C"
    diff "$W/r.$C" "$EXP" > "$W/d.$C" || { echo "FAIL fuse ($K, $C): -Wpar-auto says otherwise:"; cat "$W/d.$C"; fail=1; }
    "$XC" -q -O2 -H . -fno-par-fuse -Wpar-auto -o "$W/n.$C" "$F" > "$W/nw.$C" 2>&1 || { echo "FAIL fuse ($K, $C): no -fno-par-fuse build"; fail=1; continue; }
    grep -q "run as one block" "$W/nw.$C" && { echo "FAIL fuse ($K, $C): -fno-par-fuse fused blocks"; fail=1; }
    for m in cpu gpu; do
        for b in f n; do
            got=$( (cd "$W" && XC_PAR=$m "./$b.$C") 2>/dev/null)
            [ "$got" = "$want" ] || { echo "FAIL fuse ($K, $C, $b, $m): '$(echo "$got" | head -3)'"; fail=1; }
        done
    done
    "$XC" -q -O2 -H . -S -o "$W/s.$C.$K.s" "$F" > /dev/null 2>&1
    built="$built $C"
done
if [ -f "$W/s.xcc-xc.$K.s" ] && [ -f "$W/s.xcc.$K.s" ] && ! cmp -s "$W/s.xcc-xc.$K.s" "$W/s.xcc.$K.s"; then
    echo "FAIL fuse ($K): the two builds' code differs"; fail=1
fi
done
[ $fail = 0 ] && echo "--- fuse: pass ($built ) ---"
exit $fail
