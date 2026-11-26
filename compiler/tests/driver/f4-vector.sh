#!/bin/bash
# f4-vector.sh — the loop vectoriser leaves f4 loops scalar. An f4 element is
# a nibble, and a vector of byte stores over an f4 array would write the two
# elements of one byte from two lanes at once. A u8 copy loop beside it shows
# the vectoriser is on (SIMD on arm64, clones on x86-64); the f4 copy and
# negation loops have neither, and their results are checked on this host.
#
#   bash tests/driver/f4-vector.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/v.xc" <<'XC'
#import "Stdio.xc"
f4 a[1001];
f4 b[1001];
u8 c[1001];
u8 d[1001];
void copy4(u32 n) { for (u32 i = 0; i < n; i++) :goal(speed) { b[i] = a[i]; } }
void neg4(u32 n) { for (u32 i = 0; i < n; i++) :goal(speed) { b[i] = -b[i]; } }
void copy8(u32 n) { for (u32 i = 0; i < n; i++) :goal(speed) { d[i] = c[i]; } }
i32 main(void)
    {
    for (u32 i = 0; i < 1001; i++)
        a[i] = (f4)(f32)(i % 9);
    copy4(1001);
    neg4(1001);
    copy8(1001);
    u32 bad = 0;
    for (u32 i = 0; i < 1001; i++)
        if (b[i] != -a[i])
            bad++;
    Stdio.printf("bad %u\n", bad);
    return 0;
    }
XC
body() {  # <asm> <function>: its code up to the next global label
    awk -v L="^_?$2:\$" '$0 ~ L {f=1; next} f && /^_?[A-Za-z_][A-Za-z0-9_$]*:$/ && !/^L|^\./{exit} f' "$1"
}
for A in arm64 x86_64; do
    "$XC" -q -A $A -O2 --par-style=cpu -H . -S -o "$W/v.$A.s" "$W/v.xc" > "$W/v.$A.err" 2>&1 \
        || { echo "FAIL f4-vector: $A does not build"; head -3 "$W/v.$A.err"; fail=1; continue; }
    simd='xmm|ymm|zmm|v[0-9]+\.(16b|8b|8h|4s|2d)|q[0-9]+,'
    for fn in copy4 neg4; do
        n=$(body "$W/v.$A.s" $fn | grep -cE "$simd")
        [ "$n" = 0 ] || { echo "FAIL f4-vector: $A $fn has $n vector instructions"; fail=1; }
        grep -qE "^_?$fn\\\$" "$W/v.$A.s" && { echo "FAIL f4-vector: $A $fn has SIMD clones"; fail=1; }
    done
    on=$(body "$W/v.$A.s" copy8 | grep -cE "$simd")
    grep -qE '^_?copy8\$(avx2|base):' "$W/v.$A.s" && on=1
    [ "$on" -gt 0 ] || { echo "FAIL f4-vector: $A did not vectorise the u8 loop, so the test shows nothing"; fail=1; }
done
"$XC" -q -O2 --par-style=cpu -H . -o "$W/v" "$W/v.xc" > /dev/null 2>&1 && got=$("$W/v") || got="no build"
[ "$got" = "bad 0" ] || { echo "FAIL f4-vector: the f4 loops give '$got'"; fail=1; }
[ $fail = 0 ] && echo "--- f4-vector: ok ---"
exit $fail
