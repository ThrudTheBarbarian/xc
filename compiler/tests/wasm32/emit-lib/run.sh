#!/bin/bash
# W2 guard: multi-module --emit-lib end-to-end + twin byte-identity.
#
# Builds libTheLib.wasm (a class with a method, a protocol conformance and a
# subclass) with `xcc --emit-lib -A wasm32`, then an app that `#import
# <TheLib>`s it, and runs the pair under Node — exercising every cross-module
# feature the design names: `new` of a library class, a method call, protocol
# dispatch, an ancestry downcast (both directions), an APP subclass of a
# LIBRARY class (vtable parent-link fixup through the __addr_ getter), and a
# `^` bound method taken on a library object.
#
# Then the twin gate: the differential harnesses never build libraries, so
# this script IS the twin coverage (like return-call/run.sh) — the ported
# back end (Wasm32.xc) and writer (Wasm.xc) must produce byte-identical WAT
# and .wasm for BOTH the --emit-lib and the --link-libs build, at -O0 and -O2.
#
# Usage: bash tests/wasm32/emit-lib/run.sh   (from the repo root)
set -e
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BIN="$ROOT/bin/osx"; [ -d "$BIN" ] || BIN="$ROOT/bin/linux"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LIB="$ROOT/tests/wasm32/emit-lib/TheLib.xc"
APP="$ROOT/tests/wasm32/emit-lib/app.xc"
cd "$TMP"

# 1. Library, then app, then run: every cross-module path must answer.
"$BIN/xcc" --emit-lib -A wasm32 -H "$ROOT" -q -o libTheLib "$LIB"
[ -f libTheLib.wasm ] && [ -f libTheLib.json ] || { echo "FAIL: lib outputs missing" >&2; exit 1; }
"$BIN/xcc" -A wasm32 -H "$ROOT" -q -L . -o app "$APP"
OUT="$(node app.js)"
WANT=$'greet=42\nping=51\nloud=90\ndown=1\nnotdown=0\nextra=126\nxdown=1\nbound=86\ngreeter base=40'
[ "$OUT" = "$WANT" ] || { echo "FAIL: unexpected output:" >&2; echo "$OUT" >&2; exit 1; }

# 1b. The SAME, built by the SHIPPED compiler — both halves, and every mixture.
#     This is the part that matters: the reference is the bootstrap, and a
#     library path that only works there is a library path that does not ship.
#     Run as a MATRIX because it is what localised private:docs/bugs/096 — the library
#     xcc-xc emitted was already correct and the app was not, which a
#     both-sides-shipped test alone would have reported as "the library is
#     broken".
for LIBC in xcc xcc-xc; do
  for APPC in xcc xcc-xc; do
    rm -rf "$TMP/mix"; mkdir -p "$TMP/mix"; cd "$TMP/mix"
    "$BIN/$LIBC" --emit-lib -A wasm32 -H "$ROOT" -q -o libTheLib "$LIB"
    "$BIN/$APPC" -A wasm32 -H "$ROOT" -q -L . -o app "$APP"
    OUT="$(node app.js 2>&1)"
    [ "$OUT" = "$WANT" ] || {
        echo "FAIL: lib=$LIBC app=$APPC produced:" >&2; echo "$OUT" >&2; exit 1; }
  done
done
cd "$TMP"

# 2. The `.xtc.iface` custom section is what made `#import <TheLib>` resolve;
#    prove it is in the binary (a missing section would have failed above,
#    but say so explicitly — the section is the library's public contract).
grep -q "xtc.iface" libTheLib.wasm || { echo "FAIL: no xtc.iface custom section" >&2; exit 1; }

# 3. Twin byte-identity, lib AND app, WAT and .wasm, -O0 and -O2.
#    (tools built -O1: the -O2 call-body unroller tips Wasm32$placeData
#    over the 16 KB arm64 frame budget — same note as wasm-diff.sh.)
"$BIN/xcc" -O1 -A arm64 -H "$ROOT" -q -o xtcgwasm "$ROOT/selfhost/tools/xtcgwasm.xc" \
    -I "$ROOT/selfhost/ir" -I "$ROOT/selfhost/opt" -I "$ROOT/selfhost/codegen"
"$BIN/xcc" -O1 -A arm64 -H "$ROOT" -q -o xtlnwasm "$ROOT/selfhost/tools/xtlnwasm.xc" \
    -I "$ROOT/selfhost/asm"
"$BIN/xcc-fe" -A wasm32 -H "$ROOT" -q --emit-lib "$LIB" -o lib.ir >/dev/null 2>&1
"$BIN/xcc-fe" -A wasm32 -H "$ROOT" -q -L . "$APP" -o app.ir >/dev/null 2>&1
for O in 0 2; do
    "$BIN/xcc-cg-wasm32" -O$O -q --emit-lib -o lo$O.wat lib.ir
    ./xtcgwasm -O$O --emit-lib lib.ir -o lp$O.wat
    cmp lo$O.wat lp$O.wat || { echo "FAIL: lib WAT diverges at -O$O" >&2; exit 1; }
    "$BIN/xcc-ln-wasm32" lo$O.wat lo$O -q --emit-lib
    ./xtlnwasm lo$O.wat -o lp$O.wasm
    cmp lo$O.wasm lp$O.wasm || { echo "FAIL: lib .wasm diverges at -O$O" >&2; exit 1; }
    "$BIN/xcc-cg-wasm32" -O$O -q --link-libs -o ao$O.wat app.ir
    ./xtcgwasm -O$O --link-libs app.ir -o ap$O.wat
    cmp ao$O.wat ap$O.wat || { echo "FAIL: app WAT diverges at -O$O" >&2; exit 1; }
    "$BIN/xcc-ln-wasm32" ao$O.wat ao$O -q
    ./xtlnwasm ao$O.wat -o ap$O.wasm
    cmp ao$O.wasm ap$O.wasm || { echo "FAIL: app .wasm diverges at -O$O" >&2; exit 1; }
done
echo "PASS"
