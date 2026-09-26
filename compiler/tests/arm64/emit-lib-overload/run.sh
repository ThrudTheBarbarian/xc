#!/bin/bash
# arm64 --emit-lib with overloaded virtual methods, as a lib x app matrix.
#
# In a library build every instance method is a vtable root, so each overload
# of a name has its own slot. A class-typed call has to dispatch through the
# slot of the overload it resolved to, both inside the library and in a
# client, and a client subclass that overrides one overload must leave the
# others alone. The library also reads Number's return-type overloads of
# `value()`, which returned 0 when the call went through another overload's
# slot.
#   bash tests/arm64/emit-lib-overload/run.sh
set -e
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BIN="$ROOT/bin/osx"; [ -d "$BIN" ] || BIN="$ROOT/bin/linux"
LIB="$ROOT/tests/arm64/emit-lib-overload/OvLib.xc"
APP="$ROOT/tests/arm64/emit-lib-overload/app.xc"
WANT="$(cat "$ROOT/tests/arm64/emit-lib-overload/expected.out")"

for LIBC in xcc xcc-xc; do
  for APPC in xcc xcc-xc; do
    TMP="$(mktemp -d)"
    ( cd "$TMP"
      "$BIN/$LIBC" --emit-lib -A arm64 -H "$ROOT" -q -o libOvLib.dylib "$LIB"
      "$BIN/$APPC" -A arm64 -H "$ROOT" -q -L . -o app "$APP"
      OUT="$(./app)"
      [ "$OUT" = "$WANT" ] || { echo "FAIL: lib=$LIBC app=$APPC produced:" >&2
                                echo "$OUT" >&2; exit 1; }
    )
    rm -rf "$TMP"
  done
done
echo "PASS"
