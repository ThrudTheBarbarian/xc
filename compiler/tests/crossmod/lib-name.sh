#!/bin/bash
# lib-name.sh — an arm64 library is used whatever its file is called.
#
#   bash tests/crossmod/lib-name.sh
#
# libLnLib built for arm64 is a Mach-O file whether it is written as
# libLnLib.dylib or libLnLib.so. `#use <LnLib>` finds either; the self-hosted
# compiler read a library's interface by its EXTENSION, so the .so was taken for
# ELF, its interface was not read, and the client failed far away with
# "unsupported: assignment target" (bug 583). A compiler MATRIX (xcc, xcc-xc for
# each half), run here on the macOS arm64 host.
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${XC_BIN:-$ROOT/bin/$XC_PLAT}"
T="$ROOT/tests/crossmod"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
[ "$(uname -s)" = Darwin ] || { echo "--- lib-name: skipped (needs a macOS arm64 host) ---"; exit 0; }

fail=0
bad() { echo "FAIL  $*"; fail=$((fail+1)); }
for ext in so dylib; do
    for L in xcc xcc-xc; do
        for A in xcc xcc-xc; do
            d="$TMP/$ext-$L-$A"; mkdir -p "$d"
            ( cd "$d" && "$BIN/$L" --emit-lib -A arm64 -H "$ROOT" -q -o "libLnLib.$ext" "$T/lnlib.xc" ) \
                || { bad "$ext lib=$L: the library did not build"; continue; }
            ( cd "$d" && "$BIN/$A" -A arm64 -H "$ROOT" -q -L . -o client "$T/lnclient.xc" ) 2>"$d/err" \
                || { bad "$ext lib=$L app=$A: the client did not build"; sed 's/^/        /' "$d/err"; continue; }
            got=$(cd "$d" && DYLD_LIBRARY_PATH="$d" ./client 2>&1)
            [ "$got" = 42 ] || bad "$ext lib=$L app=$A: printed '$got', want 42"
        done
    done
done
echo "--- lib-name: $fail failing ---"
[ $fail = 0 ]
