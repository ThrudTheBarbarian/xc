#!/bin/bash
# x86-glibc-lib.sh — a glibc shared library from `--emit-lib` (from 0.73), on
# the Linux host.
#
# Each compiler builds a library that calls zlib through `-lz`, then a program
# that imports it. The library must name libc.so.6 and libz.so.1 as DT_NEEDED
# and export only its own API; the program must link against glibc and print
# what the library returns. Both compilers' libraries and programs must be
# byte-identical.
#
#   bash tests/corpus/x86-glibc-lib.sh

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/linux
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/ZLib.xc" <<'EOF'
u8* zlibVersion(void);
class ZLib
    {
    static u32 next(u32 x) { return x + (u32)1; }
    static u8* version() { return zlibVersion(); }
    }
EOF
cat > "$WORK/main.xc" <<'EOF'
#import "Stdio.xc"
#import <ZLib>
i32 main(i32 argc, u8** argv)
    {
    Stdio.printf("%u %s\n", ZLib.next((u32)41), ZLib.version());
    return 0;
    }
EOF

fail=0
for c in xcc xcc-xc; do
    mkdir -p "$WORK/$c"
    if ! "$BIN/$c" -q -A x86_64 --emit-lib "$WORK/ZLib.xc" -o "$WORK/$c/libZLib.so" -lz \
         > "$WORK/$c.log" 2>&1; then
        echo "FAIL $c: --emit-lib -lz"; head -3 "$WORK/$c.log"; fail=1; continue
    fi
    dyn=$(readelf -d "$WORK/$c/libZLib.so")
    for n in libc.so.6 libz.so.1; do
        grep -q "NEEDED.*\[$n\]" <<< "$dyn" || { echo "FAIL $c: library does not need $n"; fail=1; }
    done
    if readelf --dyn-syms -W "$WORK/$c/libZLib.so" | awk '$7 != "UND" {print $8}' \
         | grep -qx 'sqrt\|random\|_xtc_alloc'; then
        echo "FAIL $c: library exports its runtime"; fail=1
    fi
    if ! "$BIN/$c" -q -A x86_64 -L"$WORK/$c" "$WORK/main.xc" -o "$WORK/$c/prog" \
         > "$WORK/$c.log" 2>&1; then
        echo "FAIL $c: program importing the library"; head -3 "$WORK/$c.log"; fail=1; continue
    fi
    readelf -l "$WORK/$c/prog" | grep -q 'ld-linux-x86-64' \
        || { echo "FAIL $c: program is not linked against glibc"; fail=1; }
    out=$("$WORK/$c/prog" 2>&1)
    want="42 $(sed -n 's/^#define ZLIB_VERSION "\(.*\)"/\1/p' /usr/include/zlib.h 2>/dev/null)"
    [ "$want" = "42 " ] && want="42 $(readlink -f /usr/lib/x86_64-linux-gnu/libz.so.1 | sed 's/.*libz.so.//')"
    [ "$out" = "$want" ] || { echo "FAIL $c: printed '$out', expected '$want'"; fail=1; }
done
# The same paths for both, so the runpaths match too.
mkdir -p "$WORK/one"
for c in xcc xcc-xc; do
    "$BIN/$c" -q -A x86_64 --emit-lib "$WORK/ZLib.xc" -o "$WORK/one/libZLib.so" -lz >/dev/null 2>&1
    cp "$WORK/one/libZLib.so" "$WORK/one/lib.$c"
    "$BIN/$c" -q -A x86_64 -L"$WORK/one" "$WORK/main.xc" -o "$WORK/one/prog.$c" >/dev/null 2>&1
done
cmp -s "$WORK/one/lib.xcc" "$WORK/one/lib.xcc-xc" || { echo "FAIL: the two libraries differ"; fail=1; }
cmp -s "$WORK/one/prog.xcc" "$WORK/one/prog.xcc-xc" || { echo "FAIL: the two programs differ"; fail=1; }
[ "$fail" -eq 0 ] && echo "--- x86-glibc-lib: pass ---"
exit "$fail"
