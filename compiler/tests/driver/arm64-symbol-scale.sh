#!/bin/bash
# arm64-symbol-scale.sh — the arm64 back end's time grows with a module's size,
# not with its square (2026-11-02).
#
# Two lookups scanned every symbol in the module: a symbol by its name, and
# the vtable a virtual call's static receiver names, which printed every
# function's first parameter type for every virtual call. xcc.xc, which
# imports most of the tree, spent 2m20 of its 2m40 arm64 compile in them
# (22.7 s now). Both are per-module indexes now, in both compilers. The port
# also searched dead-function-elim's names and its liveness sets linearly
# (the class-table function grows with the classes); those are maps now.
#
# Checked: a generated module of N classes, each with a method called
# virtually from a small function of its own, compiled as an object (-c, as
# the split build does: every function kept, none inlined), at N and 4N.
# Four times the classes may cost up to 12x (a quadratic back end costs 16x or
# more): before the fixes the port took 33.9x (7 s -> 237 s), after them
# 10.8x, the reference 7.1x. Both compilers, and their assembly the same at
# 4N.
#
#   bash tests/driver/arm64-symbol-scale.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
N=${N:-400}
gen() {   # gen COUNT FILE
    {
    echo '#import "Stdio.xc"'
    i=0
    while [ $i -lt "$1" ]; do
        echo "class C$i { u32 v; u32 get(void) { return v + (u32)$i; } }"
        echo "u32 use$i(void) { C$i* c = new C$i(); return c.get(); }"
        i=$((i+1))
    done
    echo 'i32 main(void)'
    echo '    {'
    echo '    u32 s = (u32)0;'
    i=0
    while [ $i -lt "$1" ]; do
        echo "    s = s + use$i();"
        i=$((i+1))
    done
    echo '    Stdio.printf("%u\n", s);'
    echo '    return 0;'
    echo '    }'
    } > "$2"
}
gen "$N" "$W/small.xc"
gen $((N * 4)) "$W/big.xc"
ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
fail=0
for C in "$REF" "$XC"; do
    best() {   # the faster of two runs, in ms
        b=999999999
        for _ in 1 2; do
            t0=$(ms); "$C" -q -O2 -A arm64 -H . -c -S -o "$W/$2.s" "$1" || { echo "FAIL: $C did not build $1"; exit 1; }
            t=$(( $(ms) - t0 )); [ $t -lt $b ] && b=$t
        done
        echo $b
    }
    s=$(best "$W/small.xc" small) || { fail=1; continue; }
    b=$(best "$W/big.xc" big) || { fail=1; continue; }
    r=$(python3 -c "print('%.1f' % ($b / max($s, 1)))")
    if python3 -c "import sys; sys.exit(0 if $b <= 12 * max($s, 1) else 1)"; then
        echo "ok: $(basename "$C"): $N classes $s ms, $((N * 4)) classes $b ms (${r}x)"
    else
        echo "FAIL: $(basename "$C"): $N classes $s ms, $((N * 4)) classes $b ms (${r}x, more than 12x)"; fail=1
    fi
    cp "$W/big.s" "$W/big.$(basename "$C").s"
done
if [ $fail -eq 0 ]; then
    cmp -s "$W/big.$(basename "$REF").s" "$W/big.$(basename "$XC").s" \
        && echo "ok: the two compilers' assembly is the same" \
        || { echo "FAIL: the two compilers' assembly differs"; fail=1; }
fi
[ $fail -eq 0 ] && echo "arm64-symbol-scale: ok"
exit $fail
