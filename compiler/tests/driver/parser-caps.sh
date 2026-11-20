#!/bin/bash
# parser-caps.sh — the parser's lookaheads and ancestry walks have no fixed
# caps (#334). The port's tuple-assignment lookahead gave up after 64 tokens,
# so 33 targets were refused ("Expected ')' but found ','") where the
# reference took them; and a block in a class more than 64 classes below the
# one declaring an ivar it names said "Undefined identifier" instead of
# "a block cannot capture". Checked in both compilers.
#
#   bash tests/driver/parser-caps.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
REF=bin/$PLAT/xcc
[ -x "$XC" ] || { echo "FAIL parser-caps: no compiler at $XC"; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
# 1. Forty tuple targets.
{
    echo '#import <Stdio.xc>'
    printf 'i32'; for i in $(seq 1 39); do printf ', i32'; done
    printf ' mr(i32 x) { return (x + 0)'; for i in $(seq 1 39); do printf ', (x + %d)' $i; done; echo '; }'
    echo 'void main(void) {'
    for i in $(seq 0 39); do echo "    i32 v$i = 0;"; done
    printf '    (v0'; for i in $(seq 1 39); do printf ', v%d' $i; done; echo ') = mr(100);'
    echo '    Stdio.printf("%d %d\n", v0, v39);'
    echo '    return;'
    echo '}'
} > "$W/tup.xc"
# 2. A block naming an ivar declared seventy classes up.
{
    echo '#import <Stdio.xc>'
    echo 'class C0 { u32 x; void init(void) { x = (u32)7; } }'
    for k in $(seq 1 69); do echo "class C$k : C$((k-1)) { u32 y$k; }"; done
    echo 'class D : C69'
    echo '{'
    echo '    u32 run(void) { block a u32(u32 n) = { return x + n; } return a((u32)1); }'
    echo '}'
    echo 'void main(void) { D* d = new D(); Stdio.printf("%u\n", d.run()); return; }'
} > "$W/deep.xc"
for c in "$XC" "$REF"; do
    [ -x "$c" ] || continue
    if "$c" -q -O1 -H . -o "$W/tup" "$W/tup.xc" > "$W/out" 2>&1; then
        got=$("$W/tup")
        [ "$got" = "100 139" ] || { echo "FAIL parser-caps: $c: forty tuple targets printed '$got', want '100 139'"; fail=1; }
    else
        echo "FAIL parser-caps: $c refuses forty tuple targets: $(grep -m1 error "$W/out")"; fail=1
    fi
    "$c" -q -O1 -H . -o "$W/deep" "$W/deep.xc" > "$W/out" 2>&1
    grep -q "a block cannot capture 'x'" "$W/out" \
        || { echo "FAIL parser-caps: $c: an ivar seventy classes up: $(grep -m1 error "$W/out")"; fail=1; }
done
[ $fail = 0 ] && echo "parser-caps: ok"
exit $fail
