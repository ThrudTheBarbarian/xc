#!/bin/bash
# tensor-view-trap.sh — the run-time refusals of tensor views, in every build:
# view() of a tensor whose strides cannot give the new shape (a transposed
# one), view() and reshape() to another element count, and broadcast() of a
# dimension that is neither the target's size nor 1. Each reports what is
# wrong and stops the program with status 134; reshape() of the transposed
# tensor copies and runs.
#
#   bash tests/driver/tensor-view-trap.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/v.xc" <<'XC'
#import "Stdio.xc"
tensor<f32, 2> grid(u64 r, u64 c)
    {
    return new tensor<f32, 2>(r, c);
    }
i32 main(i32 argc, u8** argv)
    {
    tensor<f32, 2> m = grid(3, 4);
    m[2, 1] = 7.0;
    tensor<f32, 2> t = m.transpose();
    tensor<f32, 1> r = t.reshape(12);
    Stdio.printf("reshape %.1f %d\n", r[5], r.isContiguous ? 1 : 0);
    u64 n = 12;
    if (argc == 2)
        {
        tensor<f32, 1> v = t.view(12);
        Stdio.printf("view %d\n", (i32)v.count);
        }
    if (argc == 3)
        n = 10;
    tensor<f32, 1> f = m.view(n);
    if (argc == 4)
        {
        tensor<f32, 3> b = m.broadcast(2, 5, 4);
        Stdio.printf("broadcast %d\n", (i32)b.count);
        }
    if (argc == 5)
        {
        tensor<f32, 2> s = t.reshape(5, 2);
        Stdio.printf("reshape %d\n", (i32)s.count);
        }
    Stdio.printf("ran %d\n", (i32)f.count);
    return 0;
    }
XC
for opt in -O0 -O2; do
    "$XC" -q $opt -H . -o "$W/v" "$W/v.xc" > "$W/v.out" 2>&1 \
        || { echo "FAIL tensor-view-trap: $opt does not build"; head -3 "$W/v.out"; fail=1; continue; }
    got=$("$W/v" < /dev/null 2>&1 | tr '\n' ' ')
    [ "$got" = "reshape 7.0 1 ran 12 " ] || { echo "FAIL tensor-view-trap: $opt plain run gives '$got'"; fail=1; }
    for case in "x:a view the strides cannot express" \
                "x y:view() of 12 elements as 10" \
                "x y z:dimension 0 has size 3 and cannot broadcast to 5" \
                "x y z w:reshape() of 12 elements as 10"; do
        args=${case%%:*}; what=${case#*:}
        "$W/v" $args < /dev/null > "$W/o.out" 2>&1; rc=$?
        [ $rc = 134 ] || { echo "FAIL tensor-view-trap: $opt '$args' exits $rc, not 134"; fail=1; continue; }
        grep -qF "$what" "$W/o.out" || { echo "FAIL tensor-view-trap: $opt '$args' does not say '$what'"; head -4 "$W/o.out"; fail=1; }
    done
done
[ $fail = 0 ] && echo "PASS tensor-view-trap"
exit $fail
