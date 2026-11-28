#!/bin/bash
# tensor-expr-trap.sh — the run-time refusals of tensor expressions, in every
# build: operands whose shapes do not broadcast (sizes differ and neither is
# 1), and a value written into a view whose shape it does not fit. Each
# reports the dimension and the sizes and stops the program with status 134;
# shapes that broadcast run.
#
#   bash tests/driver/tensor-expr-trap.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/e.xc" <<'XC'
#import "Stdio.xc"
i32 main(i32 argc, u8** argv)
    {
    u64 n = 4;
    u64 m = 4;
    if (argc == 2)
        n = 5;
    if (argc == 3)
        m = 3;
    tensor<f32, 2> a = new tensor<f32, 2>(3, 4);
    tensor<f32, 1> b = new tensor<f32, 1>(n);
    tensor<f32, 1> r = new tensor<f32, 1>(m);
    a[1, 2] = 2.0;
    b[2] = 0.5;
    tensor<f32, 2> c = a * b + 1.0;
    a[0, ..] = r * 2.0;
    Stdio.printf("ran %.2f\n", c[1, 2]);
    return 0;
    }
XC
for opt in -O0 -O2; do
    "$XC" -q $opt -H . -o "$W/e" "$W/e.xc" > "$W/e.out" 2>&1 \
        || { echo "FAIL tensor-expr-trap: $opt does not build"; head -3 "$W/e.out"; fail=1; continue; }
    got=$("$W/e" < /dev/null 2>&1 | tr '\n' ' ')
    [ "$got" = "ran 2.00 " ] || { echo "FAIL tensor-expr-trap: $opt plain run gives '$got'"; fail=1; }
    for case in "x:=== xcc: tensor shapes that do not broadcast ===|dimension 1 of the result: sizes 4 and 5; each must be the same, or 1" \
                "x y:=== xcc: a tensor that does not fit its destination ===|dimension 0: size 3 into size 4; it must be the same, or 1"; do
        args=${case%%:*}; what=${case#*:}
        "$W/e" $args < /dev/null > "$W/o.out" 2>&1; rc=$?
        [ $rc = 134 ] || { echo "FAIL tensor-expr-trap: $opt '$args' exits $rc, not 134"; fail=1; continue; }
        for line in "${what%%|*}" "${what#*|}"; do
            grep -qF "$line" "$W/o.out" || { echo "FAIL tensor-expr-trap: $opt '$args' does not say '$line'"; head -4 "$W/o.out"; fail=1; }
        done
    done
done
[ $fail = 0 ] && echo "PASS tensor-expr-trap"
exit $fail
