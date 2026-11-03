#!/bin/bash
# x86-piv-step.sh — a stepped pointer's next value comes after its last use,
# so the two share a register and the step is one instruction (2026-11-02).
#
# pointer-iv put each pointer's step, p_next = p + step, at the TOP of the
# loop body. p_next is read only by p's back-edge phi, but defined first it
# lived across the whole body beside p, so they needed two registers; in
# int_muldiv's vector loop no second one was free, and every trip stored
# p_next to the stack and loaded it back at the back edge, which then took
# two branches. The steps now go after the rest of the body.
#
# Checked, for tests/fixtures/piv_step_tail.xc at x86-64 -O3: in main's
# AVX-512 clone, the loop that loads through the stepped pointer touches no stack
# slot and closes with a conditional branch to itself; the two compilers'
# assembly is the same; and the program built for this host prints the
# right sum.
#
#   bash tests/driver/x86-piv-step.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/piv_step_tail.xc
fail=0
"$REF" -q --par-style=cpu -H . -A x86_64 -O3 -S -o "$W/ref.s" "$F" || { echo "FAIL: $REF did not build $F"; exit 1; }
"$XC" -q --par-style=cpu -H . -A x86_64 -O3 -S -o "$W/xc.s" "$F" || { echo "FAIL: $XC did not build $F"; exit 1; }
# Each innermost loop (a label to the jump back to it, holding no other such
# span): the ones with a 512-bit load through a pointer, whether they touch
# [rbp-..], and whether they close with jmp.
# main's AVX-512 clone, where the 512-bit loads are (the library's own copy
# loops are not this fixture's).
awk '/^main[$]avx512:$/ { f = 1; next } f && /^[A-Za-z_][A-Za-z0-9_$]*:$/ { exit } f' "$W/ref.s" > "$W/main512.s"
res=$(awk '
    /^\.L[^ ]*:$/ { lab = substr($0, 1, length($0) - 1); start[lab] = NR }
    { line[NR] = $0 }
    /^\tj[a-z]+\t/ { t = $2; if (t in start && start[t] < NR) { m++; s0[m] = start[t]; e0[m] = NR; j0[m] = $1 } }
    END {
        for (a = 1; a <= m; a++) {
            inner = 1
            for (b = 1; b <= m; b++)
                if (b != a && s0[b] >= s0[a] && e0[b] <= e0[a] && (s0[b] != s0[a] || e0[b] != e0[a])) inner = 0
            if (!inner) continue
            vec = 0; slot = 0
            for (k = s0[a]; k <= e0[a]; k++) {
                if (line[k] ~ /vmovdqu(32|64)?\tzmm[0-9]+, zmmword ptr \[r[0-9a-z]+\]/) vec = 1
                if (line[k] ~ /\[rbp-/) slot = 1
            }
            if (vec) { n++; if (slot) bad++; if (j0[a] == "jmp") jmps++ }
        }
        printf "%d %d %d\n", n + 0, bad + 0, jmps + 0 }' "$W/main512.s")
set -- $res
if [ "$1" -eq 0 ]; then
    echo "FAIL: no AVX-512 loop over the array in the assembly"; fail=1
elif [ "$2" -ne 0 ] || [ "$3" -ne 0 ]; then
    echo "FAIL: of $1 such loops, $2 touch a stack slot and $3 close with jmp"; fail=1
else
    echo "ok: $1 AVX-512 loop(s) over the array, none touching a stack slot, each closed by a conditional branch"
fi
cmp -s "$W/ref.s" "$W/xc.s" && echo "ok: the two compilers' assembly is the same" \
    || { echo "FAIL: the two compilers' x86-64 assembly differs"; fail=1; }
"$XC" -q --par-style=cpu -H . -O3 -o "$W/run" "$F" && out=$("$W/run") || out="(no run)"
want=$(cat tests/fixtures/piv_step_tail.expected.out)
[ "$out" = "$want" ] && echo "ok: prints $out" || { echo "FAIL: printed '$out', want '$want'"; fail=1; }
[ $fail -eq 0 ] && echo "x86-piv-step: ok"
exit $fail
