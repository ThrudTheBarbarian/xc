#!/bin/bash
# par-vec-chain.sh — a par body that is a serial chain per item runs as
# vectors on the CPU, four side by side on arm64, in both compilers
# (2026-10-30)
#
# The escape vectoriser takes a par body's item loop (its items are
# independent by the language, so its arrays need not be proved distinct)
# and, its inner loop counted, runs four vectors of four items at once so
# their chains interleave; a block that sums adds each copy's lanes in turn
# (#21). A u8 shift amount no longer refuses the loop. Checked on
# tests/fixtures/par_vec_chain.xc: the multiply chain's block has four lane
# multiplies in its inner loop, every block has lane code, both compilers
# write the same assembly, and the program prints what it should; and on
# par_vec_chain_sum.xc, each summing block reduces four chains.
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
# A block's number, found by its name (parName's string): --par-style=auto
# lifts the program's plain loops into blocks too, and they come first.
blk() {
    awk -v want="$1" '
        function hex(h,   v, i, c) { v = 0; h = tolower(h); sub(/^0x/, "", h)
            for (i = 1; i <= length(h); i++) { c = index("0123456789abcdef", substr(h, i, 1)) - 1; v = v * 16 + c }
            return v }
        /^_ParImpl\$[0-9]+\$parName:/ { split($0, q, "$"); k = q[2]; inN = 1; next }
        inN && /_str_[0-9]+@PAGE$/ { s = $NF; sub(/@PAGE$/, "", s); str[k] = s; inN = 0 }
        /^_str_[0-9]+:$/ { cur = substr($0, 1, length($0) - 1); txt[cur] = ""; inS = 1; next }
        inS && $1 == ".byte" { v = hex($2); if (v == 0) inS = 0; else txt[cur] = txt[cur] sprintf("%c", v); next }
        { inS = 0 }
        END { for (k in str) if (txt[str[k]] == want) { print k; exit } }' "$W/x.s"
}
if [ $fail = 0 ]; then
    m=$(blk mulchain)
    [ -n "$m" ] || { echo "FAIL par-vec-chain: no block named mulchain"; fail=1; }
    n=$(fn "$m" | grep -cE '^\s+mul v[0-9]+\.4s')
    [ "$n" -ge 4 ] || { echo "FAIL par-vec-chain: the multiply chain has $n lane multiplies, not four interleaved"; fail=1; }
    for b in shiftchain floatchain narrowchain; do
        k=$(blk $b)
        [ -n "$k" ] && fn "$k" | grep -qE '\bv[0-9]+\.4s\b' || { echo "FAIL par-vec-chain: block $b has no lane code"; fail=1; }
    done
fi
if [ $fail = 0 ] && [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then
    "$XC" -q -O2 -o "$W/p" "$F" && out=$("$W/p") \
        && [ "$out" = "$(cat tests/fixtures/par_vec_chain.expected.out)" ] \
        || { echo "FAIL par-vec-chain: the program printed: ${out:-nothing}"; fail=1; }
fi
# Blocks that also sum (#21, tests/fixtures/par_vec_chain_sum.xc): four
# chains side by side too, each adding its lanes' reduction to the sum.
F=tests/fixtures/par_vec_chain_sum.xc
for s in r x; do
    c=$REF; [ $s = x ] && c=$XC
    "$c" -q -O2 -A arm64 -S -o "$W/$s.s" "$F" > "$W/e" 2>&1 \
        || { echo "FAIL par-vec-chain: $(basename "$c") does not compile the sums: $(head -c 200 "$W/e")"; fail=1; }
done
[ $fail = 0 ] && { cmp -s "$W/r.s" "$W/x.s" || { echo "FAIL par-vec-chain: the two compilers' assembly for the sums differs"; fail=1; }; }
if [ $fail = 0 ]; then
    for b in mulsum shiftsum; do
        k=$(blk $b)
        [ -n "$k" ] || { echo "FAIL par-vec-chain: no block named $b"; fail=1; continue; }
        n=$(fn "$k" | grep -cE '^\s+addv s[0-9]+, v[0-9]+\.4s')
        [ "$n" -ge 4 ] || { echo "FAIL par-vec-chain: block $b sums $n chains, not four interleaved"; fail=1; }
    done
    n=$(fn "$(blk mulsum)" | grep -cE '^\s+mul v[0-9]+\.4s')
    [ "$n" -ge 4 ] || { echo "FAIL par-vec-chain: the summed multiply chain has $n lane multiplies, not four"; fail=1; }
fi
if [ $fail = 0 ] && [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then
    "$XC" -q -O2 -o "$W/p" "$F" && out=$("$W/p") \
        && [ "$out" = "$(cat tests/fixtures/par_vec_chain_sum.expected.out)" ] \
        || { echo "FAIL par-vec-chain: the summing program printed: ${out:-nothing}"; fail=1; }
fi
[ $fail = 0 ] && echo "par-vec-chain: ok"
exit $fail
