#!/bin/bash
# arm64 --emit-lib end-to-end, both halves built by the SHIPPED compiler.
#
# The dylib WRITER is gated byte-for-byte by lddylib-diff; this checks the
# things a byte comparison cannot: that the library LOADS, that its interface
# is readable out of the `__XTC,__iface` section, that the client records an
# LC_LOAD_DYLIB and binds each import at that library's ordinal, and that
# dispatch works in both directions across the boundary.
#
# Run as a MATRIX, like the wasm32 one: it is what tells "the library is wrong"
# apart from "the client is wrong", and those failed independently here.
#   bash tests/arm64/emit-lib/run.sh
set -e
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BIN="$ROOT/bin/osx"; [ -d "$BIN" ] || BIN="$ROOT/bin/linux"
LIB="$ROOT/tests/arm64/emit-lib/TheLib.xc"
APP="$ROOT/tests/arm64/emit-lib/app.xc"
WANT=$'greet=42\nloud=90\nextra=126\ntwice=42\ngreeter base=40'

for LIBC in xcc xcc-xc; do
  for APPC in xcc xcc-xc; do
    TMP="$(mktemp -d)"
    ( cd "$TMP"
      "$BIN/$LIBC" --emit-lib -A arm64 -H "$ROOT" -q -o libTheLib.dylib "$LIB"
      "$BIN/$APPC" -A arm64 -H "$ROOT" -q -L . -o app "$APP"
      OUT="$(./app)"
      [ "$OUT" = "$WANT" ] || { echo "FAIL: lib=$LIBC app=$APPC produced:" >&2
                                echo "$OUT" >&2; exit 1; }
      # The interface must be IN the binary — that is what makes the library
      # self-describing, and a side file that goes missing is the failure it
      # exists to prevent.
      otool -l libTheLib.dylib | grep -q __iface || {
          echo "FAIL: lib=$LIBC has no __XTC,__iface section" >&2; exit 1; }
    )
    rm -rf "$TMP"
  done
done
echo "PASS"
