#!/bin/bash
# task #34 guard: a C-variadic import is rejected at wasm32 codegen, loudly.
# Usage: bash tests/wasm32/cvariadic-error/run.sh   (from the repo root)
set -e
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BIN="$ROOT/bin/osx"; [ -d "$BIN" ] || BIN="$ROOT/bin/linux"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if "$BIN/xcc" -A wasm32 -H "$ROOT" -q -o "$TMP/prog" \
       "$ROOT/tests/wasm32/cvariadic-error/prog.xc" 2>"$TMP/err"; then
    echo "FAIL: a C-variadic import compiled for wasm32" >&2; exit 1
fi
grep -q "C-variadic import" "$TMP/err" || {
    echo "FAIL: wrong error:"; cat "$TMP/err"; exit 1; }
echo "PASS"
