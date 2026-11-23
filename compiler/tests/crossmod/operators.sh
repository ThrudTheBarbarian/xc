#!/bin/bash
# operators.sh — operators defined by a class in another module.
#
#   bash tests/crossmod/operators.sh
#
# opobj.xc defines a class with `:operator(pattern)` methods and is compiled
# with -c; opmain.xc imports its interface and uses the operators. The pattern
# travels in the interface, so the program resolves `a + b` to the method as
# the defining module would. Each half is built by both compilers, every
# pairing is linked and run, and the two compilers' objects, interfaces and
# programs are compared byte for byte. arm64 (this host) only.
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/bin/$XC_PLAT"
T="$ROOT/tests/crossmod"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo "SKIP  operators.sh runs on an arm64 macOS host"
    exit 0
fi
WANT=$'sum 175\nneg -150\nscaled 75'
fail=0
bad() { echo "FAIL  $*"; fail=$((fail+1)); }
for O in xcc xcc-xc; do
    d="$TMP/obj-$O"; mkdir -p "$d"
    ( cd "$d" && "$BIN/$O" -c -A arm64 -H "$ROOT" -q -o opobj.o "$T/opobj.xc" ) || bad "$O could not compile opobj.o"
done
cmp -s "$TMP/obj-xcc/opobj.o" "$TMP/obj-xcc-xc/opobj.o" && cmp -s "$TMP/obj-xcc/opobj.xtc.iface" "$TMP/obj-xcc-xc/opobj.xtc.iface" \
    || bad "the two compilers' opobj.o or its interface differ"
grep -q '"operator"' "$TMP/obj-xcc/opobj.xtc.iface" || bad "the interface carries no operator pattern"
for O in xcc xcc-xc; do
    for M in xcc xcc-xc; do
        d="$TMP/run-$O-$M"; mkdir -p "$d"; cp "$TMP/obj-$O"/* "$d/"
        ( cd "$d" && "$BIN/$M" -c -A arm64 -H "$ROOT" -q -L . -o opmain.o "$T/opmain.xc" \
            && "$BIN/$M" -A arm64 -H "$ROOT" -q -o opmain opmain.o opobj.o ) 2>"$d/err" \
            || { bad "obj=$O main=$M: did not build"; sed 's/^/        /' "$d/err"; continue; }
        got=$("$d/opmain" 2>&1)
        [ "$got" = "$WANT" ] || { bad "obj=$O main=$M:"; echo "$got" | sed 's/^/        /'; }
    done
    cmp -s "$TMP/run-$O-xcc/opmain.o" "$TMP/run-$O-xcc-xc/opmain.o" && cmp -s "$TMP/run-$O-xcc/opmain" "$TMP/run-$O-xcc-xc/opmain" \
        || bad "obj=$O: the two compilers' opmain.o or program differ"
done
[ $fail -eq 0 ] && echo "PASS  operators.sh" || echo "operators.sh: $fail failure(s)"
[ $fail -eq 0 ]
