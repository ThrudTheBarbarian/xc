#!/bin/bash
# x86-peep.sh — three x86-64 peepholes over finished text (2026-10-25, C
# perlin 101.2 -> 97.0 ms on one thread of a Zen 5):
#   a float conversion reads and writes the value's own xmm home, not a copy
#     through xmm0;
#   in an AVX function `movss d, [m]` then `addss`/`mulss d, b` is
#     `vaddss d, b, [m]` (perlin's frame-slot constants, eight an octave);
#   `mov a, b; add a, c|k` is `lea a, [b+c|k]` when no instruction reads the
#     add's flags first, and a `mov r, r` straight after a 32-bit write of r
#     is dropped.
# perlin's avx2 block has none of the float shapes and the whole program none
# of the integer ones, the two compilers print the same code, and lea_peep.xc (its edge cases) gives its answer on Linux
# x86-64 (here, or on XC_LINUX_HOST).
#
#   bash tests/driver/x86-peep.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
SRC=../benchmark/par/perlin.xc
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
if [ -f "$SRC" ]; then
    for c in "$REF" "$XC"; do
        [ -x "$c" ] || continue
        "$c" -q -A x86_64 -O2 -H . -S -o "$W/$(basename "$c").s" "$SRC" || { echo "FAIL $c: no assembly"; fail=1; }
    done
    if [ -s "$W/xcc.s" ] && [ -s "$W/xcc-xc.s" ] && ! cmp -s "$W/xcc.s" "$W/xcc-xc.s"; then
        echo "FAIL: the two compilers' code differs"; fail=1
    fi
    S="$W/$(basename "$XC").s"
    awk '$0 == "ParImpl$0$run$avx2:" {p=1; next} p && /^[A-Za-z_][A-Za-z0-9_$]*:$/ {p=0} p' "$S" > "$W/body.s"
    [ -s "$W/body.s" ] || { echo "FAIL: perlin's block has no avx2 clone"; fail=1; }
    bad=$(awk '
        { gsub(/^[ \t]+/, ""); line = $0 }
        prev ~ /^vmovss\txmm[0-9]+, .*\[/ {
            split(prev, a, /[\t ,]+/); d = a[2]
            if (line ~ "^v(add|mul)ss\t" d ", " d ", xmm") n++ }
        { prev = line }
        END { print n + 0 }' "$W/body.s")
    [ "$bad" = 0 ] || { echo "FAIL: $bad constant loads still feed an add or multiply"; fail=1; }
    bad=$(awk '
        { gsub(/^[ \t]+/, ""); l[NR] = $0 }
        END {
            for (i = 1; i + 2 <= NR; i++) {
                if (l[i] !~ /^mov\t(e[a-z]+|r[0-9]+d), (e[a-z]+|r[0-9]+d)$/) continue
                split(l[i], a, /[\t ,]+/)
                # foldable: add of a register, or add/sub of a nonzero constant
                if (a[2] == a[3]) continue
                if (l[i+1] !~ "^add\t" a[2] ", (e[a-z]+|r[0-9]+d)$" && l[i+1] !~ "^(add|sub)\t" a[2] ", -?[1-9][0-9]*$") continue
                if (l[i+2] ~ /^(cmp|test|add|sub|and|or|xor|imul)\t/) n++
            }
            print n + 0 }' "$S")
    [ "$bad" = 0 ] || { echo "FAIL: $bad mov/add pairs before a flag-setting instruction"; fail=1; }
    bad=$(awk '
        { gsub(/^[ \t]+/, ""); line = $0 }
        line ~ /^mov\t(e[a-z]+|r[0-9]+d), (e[a-z]+|r[0-9]+d)$/ {
            split(line, a, /[\t ,]+/)
            if (a[2] == a[3] && prev ~ "^(mov|add|sub|and|or|xor|lea|imul)\t" a[2] ", ") n++ }
        { prev = line }
        END { print n + 0 }' "$S")
    [ "$bad" = 0 ] || { echo "FAIL: $bad zero-extending mov r, r after a 32-bit write"; fail=1; }
    grep -qE '^[[:space:]]*vcvttss2si[[:space:]]+rax, xmm([1-9]|1[0-5])$' "$W/body.s" \
        || { echo "FAIL: no float conversion reads its own register"; fail=1; }
else
    echo "x86-peep: no benchmark/par/perlin.xc, the code shapes skipped"
fi
H=${XC_LINUX_HOST:-}
native=$( [ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] && echo 1 || echo 0 )
if [ -n "$H" ] || [ $native = 1 ]; then
    "$XC" -q -A x86_64 -O2 -H . -o "$W/lp" tests/fixtures/lea_peep.xc || { echo "FAIL: no x86-64 lea_peep"; fail=1; }
    got=
    if [ -f "$W/lp" ] && [ $native = 1 ]; then
        got=$("$W/lp"); H=$(uname -n)
    elif [ -f "$W/lp" ]; then
        scp -q "$W/lp" "$H:/tmp/lea-peep.$$" && got=$(ssh "$H" "/tmp/lea-peep.$$; rm -f /tmp/lea-peep.$$")
    fi
    [ "$got" = "$(cat tests/fixtures/lea_peep.expected.out)" ] || { echo "FAIL: lea_peep on $H printed '$got'"; fail=1; }
fi
[ $fail = 0 ] && echo "x86-peep: ok"
exit $fail
