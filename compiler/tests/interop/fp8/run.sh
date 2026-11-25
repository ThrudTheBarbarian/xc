#!/bin/bash
# xc's 8-bit floats with C, which has no 8-bit float type and holds each value
# as its bit pattern, a uint8_t: fp8lib.c (built by clang) calls Fp8.xc's
# explicit conversions and an `extern` xc function taking an f8 through
# pointers, and returns a pattern that fp8.xc reads as an f8. With each
# compiler built here: arm64 on macOS, x86-64 on Linux.
#
#   bash tests/interop/fp8/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
command -v clang > /dev/null || { echo "--- fp8 interop: skipped (no clang) ---"; exit 0; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
if [ "$PLAT" = osx ]; then
    tgt=arm64
    clang -O2 -g -shared -install_name "$work/libfp8lib.dylib" -o "$work/libfp8lib.dylib" "$here/fp8lib.c" || exit 1
else
    tgt=x86_64
    clang -O2 -g -shared -fPIC -o "$work/libfp8lib.so" "$here/fp8lib.c" || exit 1
fi
want=$(printf 'conv 7f 7e\ne5m2 7b\ntwice 38\nvalue 3\nbits 2')
ran=0
for c in xcc-xc xcc; do
    xc="$root/bin/$PLAT/$c"
    [ -x "$xc" ] || continue
    ran=1
    if "$xc" -q -H "$root" -A $tgt -O2 -L "$work" -o "$work/fp8-$c" "$here/fp8.xc"; then
        got=$(LD_LIBRARY_PATH="$work" "$work/fp8-$c")
        if [ "$got" = "$want" ]; then echo "fp8 interop ($c, $tgt): ok"
        else echo "FAIL fp8 interop ($c, $tgt):"; diff <(echo "$want") <(echo "$got"); fail=1; fi
    else
        echo "FAIL fp8 interop ($c, $tgt): does not build"; fail=1
    fi
done
[ $ran = 1 ] || { echo "FAIL fp8 interop: no compiler in bin/$PLAT"; fail=1; }
exit $fail
