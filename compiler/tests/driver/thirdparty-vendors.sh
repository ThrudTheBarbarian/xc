#!/bin/bash
# thirdparty-vendors.sh — `#import <X>` finds X under any vendor's directory in
# the third-party tree, in both compilers (2026-10-29)
#
# The reference listed every vendor under each root; the port probed only
# <root>/X, so a vendor shipping a library under another name (acme/…/libFoo)
# was "Cannot find include file" for the port. Now both list the vendors. A
# name two vendors ship is an error naming both, in name order; `<vendor/X>`
# picks one.
#
#   bash tests/driver/thirdparty-vendors.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
cat > "$W/Foo.xc" <<'XC'
#import "Stdio.xc"
class Foo { i32 twice(i32 x) { return x * 2; } }
XC
printf '#import <Foo>\n#import "Stdio.xc"\ni32 main(i32 argc, u8** argv) { Foo* f = new Foo(); Stdio.printf("%%d\\n", f.twice(21)); return 0; }\n' > "$W/use.xc"
sed 's/<Foo>/<zed\/Foo>/' "$W/use.xc" > "$W/useq.xc"
mkdir -p "$W/one/acme/arm64" "$W/two/acme/arm64" "$W/two/zed/arm64"
"$XC" -q -A arm64 --emit-lib -o "$W/one/acme/arm64/libFoo.dylib" "$W/Foo.xc" || { echo "FAIL: the library does not build"; exit 1; }
cp "$W/one/acme/arm64/libFoo.dylib" "$W/two/acme/arm64/"
cp "$W/one/acme/arm64/libFoo.dylib" "$W/two/zed/arm64/"
for c in "$REF" "$XC"; do
    n=$(basename "$c")
    XCC_3P="$W/one" "$c" -q -A arm64 -S -o "$W/u-$n.s" "$W/use.xc" > "$W/e1-$n" 2>&1 \
        || { echo "FAIL thirdparty-vendors: $n does not find <Foo> under acme/: $(head -c 200 "$W/e1-$n")"; fail=1; }
    XCC_3P="$W/two" "$c" -q -A arm64 -S -o "$W/a-$n.s" "$W/use.xc" > "$W/e2-$n" 2>&1 \
        && { echo "FAIL thirdparty-vendors: $n took <Foo> from one of two vendors"; fail=1; }
    grep -q "matches a library from more than one third-party vendor (acme, zed)" "$W/e2-$n" \
        || { echo "FAIL thirdparty-vendors: $n does not name both vendors: $(head -c 200 "$W/e2-$n")"; fail=1; }
    XCC_3P="$W/two" "$c" -q -A arm64 -S -o "$W/q-$n.s" "$W/useq.xc" > "$W/e3-$n" 2>&1 \
        || { echo "FAIL thirdparty-vendors: $n does not take <zed/Foo>: $(head -c 200 "$W/e3-$n")"; fail=1; }
done
[ $fail = 0 ] && { cmp -s "$W/u-$(basename "$REF").s" "$W/u-$(basename "$XC").s" \
    || { echo "FAIL thirdparty-vendors: the two compilers' programs differ"; fail=1; }; }
[ $fail = 0 ] && echo "thirdparty-vendors: ok"
exit $fail
