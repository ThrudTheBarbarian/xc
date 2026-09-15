#!/bin/bash
# W5 guard: -x-wasm32,return-call end-to-end + twin byte-identity.
# Usage: bash tests/wasm32/return-call/run.sh   (from the repo root)
set -e
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BIN="$ROOT/bin/osx"; [ -d "$BIN" ] || BIN="$ROOT/bin/linux"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SRC="$ROOT/tests/wasm32/return-call/prog.xc"
cd "$TMP"

# 1. With the option: a million-deep mutual recursion completes.
"$BIN/xcc" -A wasm32 -H "$ROOT" -q -x-wasm32,return-call -o tc "$SRC"
OUT="$(node tc.js)"
[ "$OUT" = "e=1 o=1" ] || { echo "FAIL: with return-call got '$OUT'" >&2; exit 1; }

# 2. Without: it must overflow (the guard is meaningless if it passes).
"$BIN/xcc" -A wasm32 -H "$ROOT" -q -o tcn "$SRC"
if node tcn.js >/dev/null 2>&1; then
    echo "FAIL: expected stack overflow without return-call" >&2; exit 1
fi

# 3. Twin byte-identity WITH the option, at both levels: WAT and .wasm.
#    (tools built -O1: the -O2 call-body unroller tips Wasm32$placeData
#    over the 16 KB arm64 frame budget — same note as wasm-diff.sh.)
"$BIN/xcc-fe" -A wasm32 -H "$ROOT" "$SRC" -o a.ir -q >/dev/null 2>&1
"$BIN/xcc" -O1 -A arm64 -H "$ROOT" -q -o xtcgwasm "$ROOT/selfhost/tools/xtcgwasm.xc" \
    -I "$ROOT/selfhost/ir" -I "$ROOT/selfhost/opt" -I "$ROOT/selfhost/codegen"
"$BIN/xcc" -O1 -A arm64 -H "$ROOT" -q -o xtlnwasm "$ROOT/selfhost/tools/xtlnwasm.xc" \
    -I "$ROOT/selfhost/asm"
for O in 0 2; do
    "$BIN/xcc-cg-wasm32" -O$O -q -x-wasm32,return-call -o a.wat a.ir
    ./xtcgwasm -O$O -x-wasm32,return-call a.ir -o b.wat
    cmp a.wat b.wat || { echo "FAIL: WAT diverges at -O$O" >&2; exit 1; }
    "$BIN/xcc-ln-wasm32" a.wat oracle$O -q
    ./xtlnwasm a.wat -o port$O.wasm
    cmp oracle$O.wasm port$O.wasm || { echo "FAIL: .wasm diverges at -O$O" >&2; exit 1; }
done
grep -q "return_call" a.wat || { echo "FAIL: no return_call in -O2 WAT" >&2; exit 1; }
echo "PASS"
