#!/bin/bash
# opprotocols.sh — operators required by a protocol in another module.
#
#   bash tests/crossmod/opprotocols.sh
#
# opprotolib.xc defines the protocol Numeric, whose requirements are operators
# (`+`, a right-grouping `**` above `*`, `*`, an index and `|x|`), a class that
# conforms to it and a function that adds any two Numerics; it is compiled with
# -c. opprotomain.xc imports its interface, conforms a class of its own to
# Numeric and uses the operators on values typed as the protocol. The
# requirements travel in the interface, so the program's class is checked
# against them and `a ** b` parses with the library's precedence. Each half is
# built by both compilers, every pairing is linked and run, and the two
# compilers' objects, interfaces and programs are compared byte for byte.
# arm64 (this host) only.
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/bin/$XC_PLAT"
T="$ROOT/tests/crossmod"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo "SKIP  opprotocols.sh runs on an arm64 macOS host"
    exit 0
fi
WANT=$'sum 308 1564\nlib 156 1524\npower 768 4033\nindex 2 1 7\nbracket 160 16'
fail=0
bad() { echo "FAIL  $*"; fail=$((fail+1)); }
for O in xcc xcc-xc; do
    d="$TMP/obj-$O"; mkdir -p "$d"
    ( cd "$d" && "$BIN/$O" -c -A arm64 -H "$ROOT" -q -o opprotolib.o "$T/opprotolib.xc" ) || bad "$O could not compile opprotolib.o"
done
cmp -s "$TMP/obj-xcc/opprotolib.o" "$TMP/obj-xcc-xc/opprotolib.o" && cmp -s "$TMP/obj-xcc/opprotolib.xtc.iface" "$TMP/obj-xcc-xc/opprotolib.xtc.iface" \
    || bad "the two compilers' opprotolib.o or its interface differ"
grep -q '"operator"' "$TMP/obj-xcc/opprotolib.xtc.iface" || bad "the interface carries no operator pattern"
grep -q '"precedence"' "$TMP/obj-xcc/opprotolib.xtc.iface" || bad "the interface carries no operator precedence"
for O in xcc xcc-xc; do
    for M in xcc xcc-xc; do
        d="$TMP/run-$O-$M"; mkdir -p "$d"; cp "$TMP/obj-$O"/* "$d/"
        ( cd "$d" && "$BIN/$M" -c -A arm64 -H "$ROOT" -q -L . -o opprotomain.o "$T/opprotomain.xc" \
            && "$BIN/$M" -A arm64 -H "$ROOT" -q -o opprotomain opprotomain.o opprotolib.o ) 2>"$d/err" \
            || { bad "obj=$O main=$M: did not build"; sed 's/^/        /' "$d/err"; continue; }
        got=$("$d/opprotomain" 2>&1)
        [ "$got" = "$WANT" ] || { bad "obj=$O main=$M:"; echo "$got" | sed 's/^/        /'; }
    done
    cmp -s "$TMP/run-$O-xcc/opprotomain.o" "$TMP/run-$O-xcc-xc/opprotomain.o" && cmp -s "$TMP/run-$O-xcc/opprotomain" "$TMP/run-$O-xcc-xc/opprotomain" \
        || bad "obj=$O: the two compilers' opprotomain.o or program differ"
done
[ $fail -eq 0 ] && echo "PASS  opprotocols.sh" || echo "opprotocols.sh: $fail failure(s)"
[ $fail -eq 0 ]
