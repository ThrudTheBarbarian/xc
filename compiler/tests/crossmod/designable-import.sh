#!/bin/bash
# designable-import.sh — a library whose designable class conforms to a
# protocol it IMPORTED (bug 443).
#
#   dplib.xc   declares UXDesignable and UXNib
#   dqlib.xc   imports <dplib> and declares a class with an `outlet`, which the
#              compiler makes conform to dplib's UXDesignable
#
# dqlib's interface must not re-export UXDesignable or its slots: they belong
# to dplib, and a client that wants them imports dplib. Both compilers build
# both libraries, and the files must be byte-identical.
set -u
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
BIN=$ROOT/bin/$XC_PLAT; [ -x "$BIN/xcc" ] || BIN=$ROOT/bin/linux
T=$ROOT/tests/crossmod
TMP=$(mktemp -d "${TMPDIR:-/tmp}/designable-import.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
fail=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fail=$((fail+1)); }

check() {   # <arch> <ext>
    local arch=$1 ext=$2
    for C in xcc xcc-xc; do
        local d="$TMP/$arch-$C"; mkdir -p "$d"
        ( cd "$d" && "$BIN/$C" -q -H "$ROOT" -A "$arch" --emit-lib -o "libdplib.$ext" "$T/dplib.xc" \
            && "$BIN/$C" -q -H "$ROOT" -A "$arch" -L . --emit-lib -o "libdqlib.$ext" "$T/dqlib.xc" ) \
            2>"$d/err" || { bad "$arch $C: did not build"; sed 's/^/        /' "$d/err"; return; }
    done
    for f in "libdplib.$ext" "libdqlib.$ext"; do
        cmp -s "$TMP/$arch-xcc/$f" "$TMP/$arch-xcc-xc/$f" \
            && ok "$arch: the two compilers' $f agree" \
            || bad "$arch: the two compilers' $f differ"
    done
}
check wasm32 wasm
check arm64 dylib
echo "--- designable-import: $fail failing ---"
[ $fail = 0 ]
