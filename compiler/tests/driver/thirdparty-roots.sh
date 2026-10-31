#!/bin/bash
# thirdparty-roots.sh — an install finds third-party libraries in its OWN 3p,
# beside its bin/ and lib/ (2026-10-29)
#
# Owner: "They should look at both the standard (for the os) and their own
# relative path". An install at <dir> (bin/xcc, lib/xc) looks in <dir>/3p, then
# its sibling <dir>/../3p (the versioned /opt/xcc/<ver> layout), then the OS's
# standard place (/opt/xcc/3p). The library here exists only in <dir>/3p, so
# finding it with no XCC_3P is the check, for both compilers; then the same
# vendor in <dir>/3p and <dir>/../3p takes the first.
#
#   bash tests/driver/thirdparty-roots.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-$ROOT/bin/$PLAT/xcc}
XC=${XC:-$ROOT/bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
cat > "$W/Foo.xc" <<'XC'
#import "Stdio.xc"
class Foo { i32 twice(i32 x) { return x * 2; } }
XC
printf '#import <Foo>\n#import "Stdio.xc"\ni32 main(i32 argc, u8** argv) { Foo* f = new Foo(); Stdio.printf("%%d\\n", f.twice(21)); return 0; }\n' > "$W/use.xc"
# Two installs laid out as `make install` lays one out (bin/, lib/xc), one per
# compiler; the reference brings its sibling tools.
for which in ref xc; do
    I="$W/$which/compilers/xcc"
    mkdir -p "$I/bin" "$I/lib" "$I/3p/acme/arm64"
    ln -s "$ROOT/support" "$I/lib/xc"
    if [ $which = ref ]; then cp "$(dirname "$REF")"/xcc* "$I/bin/"; else cp "$XC" "$I/bin/xcc"; fi
done
"$XC" -q -A arm64 --emit-lib -o "$W/libFoo.dylib" "$W/Foo.xc" || { echo "FAIL: the library does not build"; exit 1; }
for which in ref xc; do
    I="$W/$which/compilers/xcc"
    cp "$W/libFoo.dylib" "$I/3p/acme/arm64/"
    ( cd "$W" && env -u XCC_3P -u XCC_HOME -u XTC_HOME "$I/bin/xcc" -q -A arm64 -o "$W/use-$which" "$W/use.xc" ) > "$W/err-$which" 2>&1 \
        || { echo "FAIL thirdparty-roots ($which): the install does not look in its own 3p: $(head -c 200 "$W/err-$which")"; fail=1; continue; }
    otool -l "$W/use-$which" 2>/dev/null | grep -q "$I/3p/acme/arm64" \
        || { echo "FAIL thirdparty-roots ($which): no runpath to the install's 3p"; fail=1; }
done
# `xcc --print-3p-dir` names the install's own tree, absolute (2026-10-31: a
# script that installs a library for this compiler asks it where).
for which in ref xc; do
    I="$W/$which/compilers/xcc"
    got=$(cd "$W" && env -u XCC_3P -u XCC_HOME -u XTC_HOME "$I/bin/xcc" --print-3p-dir 2>&1)
    want=$(cd "$I/3p" && pwd -P)
    [ "$(cd "$got" 2>/dev/null && pwd -P)" = "$want" ] && [ "${got#/}" != "$got" ] \
        || { echo "FAIL thirdparty-roots ($which): --print-3p-dir says '$got', want $want"; fail=1; }
done
# The same vendor in the install's own 3p and in its sibling <dir>/../3p (an
# earlier compiler's shared tree, 2026-10-31: each install has its own 3p, and
# the shared one keeps the libraries older compilers built): the own copy is
# used, and the two are not one library "from more than one vendor".
for which in ref xc; do
    I="$W/$which/compilers/xcc"
    mkdir -p "$W/$which/compilers/3p/acme/arm64"
    cp "$W/libFoo.dylib" "$W/$which/compilers/3p/acme/arm64/"
    ( cd "$W" && env -u XCC_3P -u XCC_HOME -u XTC_HOME "$I/bin/xcc" -q -A arm64 -o "$W/use2-$which" "$W/use.xc" ) > "$W/err2-$which" 2>&1 \
        || { echo "FAIL thirdparty-roots ($which): a vendor in two roots: $(head -c 200 "$W/err2-$which")"; fail=1; continue; }
    otool -l "$W/use2-$which" 2>/dev/null | grep -q "$I/3p/acme/arm64" \
        || { echo "FAIL thirdparty-roots ($which): a vendor in two roots did not take the install's own copy"; fail=1; }
done
[ $fail = 0 ] && echo "thirdparty-roots: ok"
exit $fail
