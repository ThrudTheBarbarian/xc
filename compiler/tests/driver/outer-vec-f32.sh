#!/bin/bash
# outer-vec-f32.sh — a float matrix multiply's j loop runs as f32 vectors, in
# both compilers (2026-10-30)
#
# The outer vectoriser took integer lanes only and arrays rooted at a named
# local or a global, so a float multiply over `new float[]` arrays stayed
# scalar wherever no matmul kernel replaces the loop. Checked on
# tests/fixtures/outer_vec_f32.xc with -fno-matmul, for arm64 and arm64
# Linux: lane arithmetic on .4s, the two compilers' assembly the same, and
# (on an arm64 Mac) the program prints what it prints unoptimised.
#
#   bash tests/driver/outer-vec-f32.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/outer_vec_f32.xc
fail=0
for t in arm64 arm64-linux; do
    for s in r x; do
        c=$REF; [ $s = x ] && c=$XC
        "$c" -q -O2 -fno-matmul -A $t -S -o "$W/$s-$t.s" "$F" > "$W/e" 2>&1 \
            || { echo "FAIL outer-vec-f32: $(basename "$c") -A $t does not compile it: $(head -c 200 "$W/e")"; fail=1; }
    done
    [ $fail = 0 ] || continue
    cmp -s "$W/r-$t.s" "$W/x-$t.s" || { echo "FAIL outer-vec-f32: -A $t: the two compilers' assembly differs"; fail=1; }
    n=$(grep -cE '\b(fmla|fmul|fadd) v[0-9]+\.4s' "$W/x-$t.s")
    [ "$n" -ge 1 ] || { echo "FAIL outer-vec-f32: -A $t: the j loop has no f32 lane arithmetic"; fail=1; }
done
if [ $fail = 0 ] && [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then
    "$XC" -q -O2 -fno-matmul -o "$W/p" "$F" && "$W/p" | cmp -s - tests/fixtures/outer_vec_f32.expected.out \
        || { echo "FAIL outer-vec-f32: the program prints something else"; fail=1; }
fi
[ $fail = 0 ] && echo "outer-vec-f32: ok"
exit $fail
