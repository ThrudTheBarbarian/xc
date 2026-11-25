#!/bin/bash
# f16 and bf16 across the C calling convention, against C built by clang:
# half16.xc calls half16lib.c's functions (more halves than registers, so some
# go on the stack), C calls half16.xc's `extern` functions back through
# pointers, and a variadic C function and printf take halves as doubles. The
# program must print what half16main.c, the same calls made from C and built
# by clang, prints. half16b.xc calls them without naming either type. With each compiler built here: arm64 on macOS (and win64
# under Wine, given clang's mingw root), x86-64 on Linux.
#
#   bash tests/interop/float16/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
command -v clang > /dev/null || { echo "--- float16 interop: skipped (no clang) ---"; exit 0; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
if [ "$PLAT" = osx ]; then
    tgt=arm64
    clang -O2 -g -shared -install_name "$work/libhalf16lib.dylib" -o "$work/libhalf16lib.dylib" "$here/half16lib.c" || exit 1
else
    tgt=x86_64
    clang -O2 -g -shared -fPIC -o "$work/libhalf16lib.so" "$here/half16lib.c" || exit 1
fi
clang -O2 -o "$work/main" "$here/half16main.c" -L "$work" -lhalf16lib || exit 1
want=$(LD_LIBRARY_PATH="$work" "$work/main")
# win64: the DLL built by clang for mingw, with compiler-rt for its half
# conversions and an entry point of its own (no C runtime).
mingw=${XTC_WIN64_TOOLCHAIN:-/opt/clang/win64}/x86_64-w64-mingw32
w64=0
if [ "$PLAT" = osx ] && command -v wine > /dev/null && [ -f "$mingw/clang-rt/libclang_rt.builtins-x86_64.a" ]; then
    mkdir -p "$work/w64"
    printf 'int __stdcall DllMainCRTStartup(void *h, unsigned r, void *p) { return 1; }\n' > "$work/w64/entry.c"
    clang --target=x86_64-w64-windows-gnu --sysroot="$mingw" -fuse-ld=lld -O2 -g -gdwarf -shared -nostdlib \
        -o "$work/w64/libhalf16lib.dll" "$here/half16lib.c" "$work/w64/entry.c" \
        "$mingw/clang-rt/libclang_rt.builtins-x86_64.a" -Wl,--out-implib,"$work/w64/libhalf16lib.dll.a" && w64=1
fi
check() { # $1 = what, $2 = output
    if [ "$2" = "$want" ]; then echo "float16 interop ($1): ok"
    else echo "FAIL float16 interop ($1):"; diff <(echo "$want") <(echo "$2"); fail=1; fi
}
ran=0
for c in xcc-xc xcc; do
    xc="$root/bin/$PLAT/$c"
    [ -x "$xc" ] || continue
    ran=1
    if "$xc" -q -H "$root" -A $tgt -O2 -L "$work" -o "$work/h16-$c" "$here/half16.xc"; then
        check "$c, $tgt" "$(LD_LIBRARY_PATH="$work" "$work/h16-$c")"
    else
        echo "FAIL float16 interop ($c, $tgt): does not build"; fail=1
    fi
    # The types only in the library's debug information: the conversions
    # still link.
    if "$xc" -q -H "$root" -A $tgt -O2 -L "$work" -o "$work/h16b-$c" "$here/half16b.xc"; then
        got=$(LD_LIBRARY_PATH="$work" "$work/h16b-$c")
        [ "$got" = "$(printf 'h_add 1.75\nh_neg -2\nbf_id 3.5')" ] && echo "float16 interop ($c, $tgt, unnamed): ok" \
            || { echo "FAIL float16 interop ($c, $tgt, unnamed):"; echo "$got"; fail=1; }
    else
        echo "FAIL float16 interop ($c, $tgt, unnamed): does not build"; fail=1
    fi
    [ $w64 = 1 ] || continue
    if "$xc" -q -H "$root" -A win64 -O2 -L "$work/w64" -o "$work/w64/h16-$c.exe" "$here/half16.xc"; then
        check "$c, win64" "$(cd "$work/w64" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d" wine "h16-$c.exe" 2> /dev/null | tr -d '\r')"
    else
        echo "FAIL float16 interop ($c, win64): does not build"; fail=1
    fi
done
[ $ran = 1 ] || { echo "FAIL float16 interop: no compiler in bin/$PLAT"; fail=1; }
exit $fail
