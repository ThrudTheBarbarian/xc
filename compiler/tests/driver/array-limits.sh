#!/bin/bash
# array-limits.sh — array sizes past 32 bits are errors (#293). A count of
# 2^32 wrapped to 0, and an array of more than 4 GB was given storage of its
# size mod 2^32 while .length kept the count, so writes ran off the end.
# Both compilers refuse a count past 32 bits and a global, local or field
# array past 4 GB, on every target, with a message that says to allocate it
# with new T[n] (#321), and still build a 4 GB - 1 byte array.
#
#   bash tests/driver/array-limits.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
printf '#import "Stdio.xc"\nu8 g[4294967296];\ni32 main(void) { return 0; }\n' > "$W/count.xc"
printf '#import "Stdio.xc"\ndouble a[600000000];\ni32 main(void) { a[1] = 1.0d; return 0; }\n' > "$W/global.xc"
printf '#import "Stdio.xc"\ni32 main(void) { double loc[700000000]; loc[3] = 1.0d; Stdio.printf("%%f\\n", loc[3]); return 0; }\n' > "$W/local.xc"
printf '#import "Stdio.xc"\nclass Big : Object { double v[600000000]; }\ni32 main(void) { return 0; }\n' > "$W/field.xc"
printf '#import "Stdio.xc"\nu8 a[4294967295];\ni32 main(void) { a[5] = (u8)1; return 0; }\n' > "$W/edge.xc"
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    n=$(basename "$c")
    for f in count:"elements is past 4 GB; allocate it with new T\[n\]" global:"bytes, past 4 GB; allocate it with new T\[n\]" local:"bytes, past 4 GB; allocate it with new T\[n\]" field:"bytes, past 4 GB; allocate it with new T\[n\]"; do
        src=${f%%:*}; want=${f#*:}
        if "$c" -q -H . -S -o "$W/o.s" "$W/$src.xc" > "$W/e" 2>&1; then
            echo "FAIL $n: the $src case built"; fail=1
        elif ! grep -q "$want" "$W/e"; then
            echo "FAIL $n: the $src case refused without '$want': $(head -c 200 "$W/e")"; fail=1
        fi
    done
    "$c" -q -H . -S -o "$W/o.s" "$W/edge.xc" > "$W/e" 2>&1 || { echo "FAIL $n: a 4 GB - 1 byte array refused: $(head -c 200 "$W/e")"; fail=1; }
done
[ $fail = 0 ] && echo "array-limits: ok"
exit $fail
