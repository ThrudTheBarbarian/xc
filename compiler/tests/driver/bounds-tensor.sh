#!/bin/bash
# bounds-tensor.sh — checked builds (-fbounds-check) check each tensor index
# against its dimension's shape, at the subscript's site, the dimension named
# beside it: one index past the end in each dimension of a rank-3 tensor stops
# the program (status 134); indices in range run. f4 elements count as
# elements. Without -fbounds-check the program has no checks.
#
#   bash tests/driver/bounds-tensor.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/b.xc" <<'XC'
#import "Stdio.xc"
i32 main(i32 argc, u8** argv)
    {
    tensor<f32, 3> t = new tensor<f32, 3>(2, 3, 4);
    tensor<f4, 1> q = new tensor<f4, 1>(5);
    u64 i = 1;
    u64 j = 2;
    u64 k = 3;
    u64 e = 4;
    if (argc == 2)
        i = 2;
    if (argc == 3)
        j = 3;
    if (argc == 4)
        k = 4;
    if (argc == 5)
        e = 5;
    t[i, j, k] = 1.5;
    q[e] = 1.0;
    Stdio.printf("in range %f %f\n", t[i, j, k], q[e]);
    return 0;
    }
XC
"$XC" -q -O2 -fbounds-check -H . -o "$W/b" "$W/b.xc" > "$W/b.out" 2>&1 \
    || { echo "FAIL bounds-tensor: the checked build does not build"; head -3 "$W/b.out"; exit 1; }
got=$("$W/b" < /dev/null 2>&1 | head -1)
[ "$got" = "in range 1.500000 1.000000" ] || { echo "FAIL bounds-tensor: in-range run gives '$got'"; fail=1; }
for case in "x:0:b.xc:18:" "x y:1:b.xc:18:" "x y z:2:b.xc:18:" "x y z w:0:b.xc:19:"; do
    args=${case%%:*}; rest=${case#*:}; dim=${rest%%:*}; site=${rest#*:}
    "$W/b" $args < /dev/null > "$W/o.out" 2>&1; rc=$?
    [ $rc = 134 ] || { echo "FAIL bounds-tensor: '$args' exits $rc, not 134"; fail=1; continue; }
    grep -q "${site}.*dimension $dim" "$W/o.out" || { echo "FAIL bounds-tensor: '$args' does not report ${site} dimension $dim"; head -4 "$W/o.out"; fail=1; }
done
# Without the flag: no checks in the program.
"$XC" -q -O2 -H . -S -o "$W/n.s" "$W/b.xc" > /dev/null 2>&1 || { echo "FAIL bounds-tensor: the plain build does not build"; fail=1; }
if grep -q '_xt_check_bounds' "$W/n.s"; then echo "FAIL bounds-tensor: an unchecked build calls a check"; fail=1; fi
[ $fail = 0 ] && echo "PASS bounds-tensor"
exit $fail
