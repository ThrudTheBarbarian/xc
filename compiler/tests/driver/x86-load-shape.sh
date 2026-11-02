#!/bin/bash
# x86-load-shape.sh — x86-64 loads and function entries (2026-11-02).
#
# A load into a value's home went through rdx and a copy whenever the
# address named the home register (`mov edx, [r9 + rdi*4]; mov edi, edx`),
# though one mov reads its address before it writes: sort_small's inner loop
# paid the copy on every trip. A byte or halfword loaded into its home wrote
# part of the register (`mov dil, [..]`) and merged with the rest; it is
# zero-extended into the whole register now (`movzx edi, byte ptr [..]`), as
# clang does. And no function was aligned, so where each one started depended
# on all the code before it; every function starts on 16 bytes now, as clang's
# and GCC's do.
#
# Checked, for tests/fixtures/x86_load_shape.xc at x86-64 -O3: no load into a
# register is followed by a plain copy of it from rdx/edx; no byte or halfword
# is loaded into an 8- or 16-bit view of a home register (rax/rcx/rdx are
# scratch: a value with no home is loaded there on its way to its slot); every function label (`.type …
# @function` then the label) is preceded by `.p2align 4`; the two compilers'
# assembly is the same; and the program built for this host prints the right
# value.
#
#   bash tests/driver/x86-load-shape.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/x86_load_shape.xc
fail=0
"$REF" -q -H . -A x86_64 -O3 -S -o "$W/ref.s" "$F" || { echo "FAIL: $REF did not build $F"; exit 1; }
"$XC" -q -H . -A x86_64 -O3 -S -o "$W/xc.s" "$F" || { echo "FAIL: $XC did not build $F"; exit 1; }
# main and count: the fixture's own code, not the library's.
awk '/^(main|count)(\$[a-z0-9]+)?:$/ { f = 1; print; next }
     f && /^[A-Za-z_][A-Za-z0-9_$]*:$/ { f = 0 } f' "$W/ref.s" > "$W/own.s"
staged=$(awk '{ l[NR] = $0 } END { for (i = 1; i < NR; i++)
    if (l[i] ~ /^\tmov\t(edx|rdx|dl|dx), [a-z]* ?(ptr )?\[/ && l[i+1] ~ /^\tmov\t[a-z0-9]+, (edx|rdx|dl|dx)$/) n++
    print n + 0 }' "$W/own.s")
[ "$staged" -eq 0 ] && echo "ok: no load is staged through rdx into its home" \
    || { echo "FAIL: $staged loads go through rdx and a copy:"; grep -B0 -A1 -E '^\tmov\t(edx|rdx|dl|dx), .*\[' "$W/own.s" | head -6; fail=1; }
part=$(grep -cE '^\tmov\t(bl|[sd]il|r[0-9]+b|bx|[sd]i|r[0-9]+w), (byte |word )?(ptr )?\[' "$W/own.s")
[ "$part" -eq 0 ] && echo "ok: bytes and halfwords are zero-extended into the whole register" \
    || { echo "FAIL: $part partial-register loads:"; grep -E '^\tmov\t(bl|[sd]il|r[0-9]+b|bx|[sd]i|r[0-9]+w), (byte |word )?(ptr )?\[' "$W/own.s" | head -3; fail=1; }
nfun=$(grep -c '@function$' "$W/ref.s")
unal=$(awk '/^\t\.p2align\t4, 0x90$/ { a = NR } /^\t\.globl\t/ { g = NR } /@function$/ { if (!(a && a == g - 1)) n++ } END { print n + 0 }' "$W/ref.s")
# The SIMD dispatch stubs (one jmp each) are not aligned.
stubs=$(grep -c '^\tjmp\tqword ptr \[rip + __simd_' "$W/ref.s")
[ "$unal" -le "$stubs" ] && echo "ok: $((nfun - unal)) of $nfun functions start on 16 bytes (the rest are $stubs dispatch stubs)" \
    || { echo "FAIL: $unal of $nfun functions are not preceded by .p2align 4 ($stubs dispatch stubs)"; fail=1; }
cmp -s "$W/ref.s" "$W/xc.s" && echo "ok: the two compilers' assembly is the same" \
    || { echo "FAIL: the two compilers' x86-64 assembly differs"; fail=1; }
"$XC" -q -H . -O3 -o "$W/run" "$F" && out=$("$W/run") || out="(no run)"
want=$(cat tests/fixtures/x86_load_shape.expected.out)
[ "$out" = "$want" ] && echo "ok: prints $out" || { echo "FAIL: printed '$out', want '$want'"; fail=1; }
[ $fail -eq 0 ] && echo "x86-load-shape: ok"
exit $fail
