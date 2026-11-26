#!/bin/bash
# xc's f4 arrays with C, which has no 4-bit float type and sees an f4 array
# as bytes, two elements to each, element 0 in the low nibble: fp4lib.c
# (built by clang) writes and reads elements, calls Fp4.xc's conversions, and
# calls an `extern` xc function taking an f4 array through a pointer. With
# each compiler built here: arm64 on macOS, x86-64 on Linux.
#
#   bash tests/interop/fp4/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
command -v clang > /dev/null || { echo "--- fp4 interop: skipped (no clang) ---"; exit 0; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
if [ "$PLAT" = osx ]; then
    tgt=arm64
    clang -O2 -g -shared -install_name "$work/libfp4lib.dylib" -o "$work/libfp4lib.dylib" "$here/fp4lib.c" || exit 1
else
    tgt=x86_64
    clang -O2 -g -shared -fPIC -o "$work/libfp4lib.so" "$here/fp4lib.c" || exit 1
fi
want=$(printf 'get 1 d 4\nsum 0.5\ndoubled 1 -6 4\nconv 4 f')
ran=0
for c in xcc-xc xcc; do
    xc="$root/bin/$PLAT/$c"
    [ -x "$xc" ] || continue
    ran=1
    if "$xc" -q -H "$root" -A $tgt -O2 -L "$work" -o "$work/fp4-$c" "$here/fp4.xc"; then
        got=$(LD_LIBRARY_PATH="$work" "$work/fp4-$c")
        if [ "$got" = "$want" ]; then echo "fp4 interop ($c, $tgt): ok"
        else echo "FAIL fp4 interop ($c, $tgt):"; diff <(echo "$want") <(echo "$got"); fail=1; fi
    else
        echo "FAIL fp4 interop ($c, $tgt): does not build"; fail=1
    fi
done
[ $ran = 1 ] || { echo "FAIL fp4 interop: no compiler in bin/$PLAT"; fail=1; }
exit $fail
