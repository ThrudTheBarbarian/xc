#!/bin/bash
# par-vec-chain.sh — a par body that is a serial chain per item runs as
# vectors on the CPU, four side by side on arm64, in both compilers
# (2026-10-30)
#
# The escape vectoriser takes a par body's item loop (its items are
# independent by the language, so its arrays need not be proved distinct)
# and, its inner loop counted and nothing summed across items, runs four
# vectors of four items at once so their chains interleave. A u8 shift amount
# no longer refuses the loop. Checked on tests/fixtures/par_vec_chain.xc: the
# multiply chain's block has four lane multiplies in its inner loop, every
# block has lane code, both compilers write the same assembly, and the
# program prints what it should.
#
#   bash tests/driver/par-vec-chain.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
F=tests/fixtures/par_vec_chain.xc
for s in r x; do
    c=$REF; [ $s = x ] && c=$XC
    "$c" -q -O2 -A arm64 -S -o "$W/$s.s" "$F" > "$W/e" 2>&1 \
        || { echo "FAIL par-vec-chain: $(basename "$c") does not compile it: $(head -c 200 "$W/e")"; fail=1; }
done
[ $fail = 0 ] && { cmp -s "$W/r.s" "$W/x.s" || { echo "FAIL par-vec-chain: the two compilers' assembly differs"; fail=1; }; }
fn() { awk -v f="_ParImpl\$$1\$run:" '$0 == f {p=1; next} p && /^_ParImpl\$[0-9]+\$[a-zA-Z]+:/ {exit} p' "$W/x.s"; }
if [ $fail = 0 ]; then
    n=$(fn 0 | grep -cE '^\s+mul v[0-9]+\.4s')
    [ "$n" -ge 4 ] || { echo "FAIL par-vec-chain: the multiply chain has $n lane multiplies, not four interleaved"; fail=1; }
    for k in 1 2 3; do
        fn $k | grep -qE '\bv[0-9]+\.4s\b' || { echo "FAIL par-vec-chain: block $k has no lane code"; fail=1; }
    done
fi
if [ $fail = 0 ] && [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then
    "$XC" -q -O2 -o "$W/p" "$F" && out=$("$W/p") \
        && [ "$out" = "$(cat tests/fixtures/par_vec_chain.expected.out)" ] \
        || { echo "FAIL par-vec-chain: the program printed: ${out:-nothing}"; fail=1; }
fi
[ $fail = 0 ] && echo "par-vec-chain: ok"
exit $fail
