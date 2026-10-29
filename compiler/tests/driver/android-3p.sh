#!/bin/bash
# android-3p.sh — an android build finds a third-party library in the vendor's
# android/ directory, in both compilers (target-table step 0, 2026-10-29)
#
# The reference's front end runs as its own process and is handed -m arm64
# -DPLATFORM_android=1, so it looked only in <vendor>/arm64: a library shipped
# for android alone was "Cannot find include file". The port looks in
# <vendor>/android first, then <vendor>/arm64. Both must now build the same
# client, byte for byte.
#
#   bash tests/driver/android-3p.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
mkdir -p "$W/root/Foo/android"
cat > "$W/Foo.xc" <<'XC'
#import "Stdio.xc"
class Foo { i32 twice(i32 x) { return x * 2; } }
XC
cat > "$W/use.xc" <<'XC'
#import <Foo>
#import "Stdio.xc"
i32 main(i32 argc, u8** argv) { Foo* f = new Foo(); Stdio.printf("%d\n", f.twice(21)); return 0; }
XC
"$XC" -q -A android --emit-lib -o "$W/root/Foo/android/libFoo.so" "$W/Foo.xc" || { echo "FAIL: the android library does not build"; exit 1; }
fail=0
for c in "$REF" "$XC"; do
    XCC_3P="$W/root" "$c" -q -A android -o "$W/use-$(basename "$c")" "$W/use.xc" > "$W/err" 2>&1 \
        || { echo "FAIL android-3p: $(basename "$c") does not find <Foo> in Foo/android: $(head -c 200 "$W/err")"; fail=1; }
done
[ $fail = 0 ] && { cmp -s "$W/use-$(basename "$REF")" "$W/use-$(basename "$XC")" \
    || { echo "FAIL android-3p: the two compilers' programs differ"; fail=1; }; }
[ $fail = 0 ] && echo "android-3p: ok"
exit $fail
