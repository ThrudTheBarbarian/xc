#!/bin/bash
# Platform-prelude guard: Browser.fetch/log with no directives in app source,
# completions round-tripping through the loader's built-in browser package.
# Usage: bash tests/wasm32/platform-browser/run.sh   (from the repo root)
set -e
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BIN="$ROOT/bin/osx"; [ -d "$BIN" ] || BIN="$ROOT/bin/linux"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$ROOT/tests/wasm32/platform-browser/check.js" "$TMP/"
cd "$TMP"
"$BIN/xcc" -A wasm32 -H "$ROOT" -q -o app "$ROOT/tests/wasm32/platform-browser/app.xc"
OUT="$(node check.js)"
echo "$OUT"
[ "$OUT" = "PASS" ] || { echo "FAIL: unexpected output" >&2; exit 1; }
