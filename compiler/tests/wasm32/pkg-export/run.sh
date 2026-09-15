#!/bin/bash
# §6 guard: #package + extern generalisation, end-to-end under Node.
# Usage: bash tests/wasm32/pkg-export/run.sh   (from the repo root)
set -e
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BIN="$ROOT/bin/osx"; [ -d "$BIN" ] || BIN="$ROOT/bin/linux"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$ROOT/tests/wasm32/pkg-export/check.js" "$TMP/"
cd "$TMP"
"$BIN/xcc" -A wasm32 -H "$ROOT" -q -o prog "$ROOT/tests/wasm32/pkg-export/prog.xc"
OUT="$(node check.js)"
echo "$OUT"
WANT=$'ping 7\n23\n22\n22\nPASS'
[ "$OUT" = "$WANT" ] || { echo "FAIL: unexpected output" >&2; exit 1; }
