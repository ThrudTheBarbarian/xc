#!/bin/bash
# bounds-tensor-slice.sh — checked builds (-fbounds-check) check a tensor
# slice before it is taken: each range keeps 0 <= start <= end <= shape, and
# each index in the slice is below its dimension's shape. A failure reports
# the slice's site with the dimension and the bounds, and stops the program
# (status 134); slices in range run. Without -fbounds-check there are no
# checks.
#
#   bash tests/driver/bounds-tensor-slice.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/s.xc" <<'XC'
#import "Stdio.xc"
i32 main(i32 argc, u8** argv)
    {
    tensor<f32, 3> t = new tensor<f32, 3>(2, 3, 4);
    u64 a = 1;
    u64 b = 3;
    u64 i = 1;
    u64 e = 3;
    if (argc == 2)
        b = 4;
    if (argc == 3)
        a = 4;
    if (argc == 4)
        i = 2;
    if (argc == 5)
        e = 4;
    tensor<f32, 2> s = t[i, a..b, ...e];
    Stdio.printf("in range %d %d\n", (i32)s.shape(0), (i32)s.shape(1));
    return 0;
    }
XC
"$XC" -q -O2 -fbounds-check -H . -o "$W/s" "$W/s.xc" > "$W/s.out" 2>&1 \
    || { echo "FAIL bounds-tensor-slice: the checked build does not build"; head -3 "$W/s.out"; exit 1; }
got=$("$W/s" < /dev/null 2>&1 | head -1)
[ "$got" = "in range 2 4" ] || { echo "FAIL bounds-tensor-slice: in-range run gives '$got'"; fail=1; }
# args : what the report says
for case in "x:dimension 1:slice 1..4, but the dimension holds 3 elements" \
            "x y:dimension 1:slice 4..3, but the dimension holds 3 elements" \
            "x y z:dimension 0:index 2, but it holds 2 elements" \
            "x y z w:dimension 2:slice 0...4, but the dimension holds 4 elements"; do
    args=${case%%:*}; rest=${case#*:}; dim=${rest%%:*}; what=${rest#*:}
    "$W/s" $args < /dev/null > "$W/o.out" 2>&1; rc=$?
    [ $rc = 134 ] || { echo "FAIL bounds-tensor-slice: '$args' exits $rc, not 134"; fail=1; continue; }
    grep -q "s.xc:17:.*$dim" "$W/o.out" || { echo "FAIL bounds-tensor-slice: '$args' does not report s.xc:17 $dim"; head -4 "$W/o.out"; fail=1; }
    grep -qF "$what" "$W/o.out" || { echo "FAIL bounds-tensor-slice: '$args' does not say '$what'"; head -4 "$W/o.out"; fail=1; }
done
# Without the flag: no checks in the program.
"$XC" -q -O2 -H . -S -o "$W/n.s" "$W/s.xc" > /dev/null 2>&1 || { echo "FAIL bounds-tensor-slice: the plain build does not build"; fail=1; }
calls=$(grep -E '(bl|call|jsr)[[:space:]]+_?_xt_check_(bounds|tensor_slice)' "$W/n.s" | wc -l | tr -d ' ')
[ "$calls" = 0 ] || { echo "FAIL bounds-tensor-slice: an unchecked build calls a check"; fail=1; }
[ $fail = 0 ] && echo "PASS bounds-tensor-slice"
exit $fail
