#!/bin/bash
# 091 — a wasm32 library making a VIRTUAL call on an object the APP created.
#
# The library and the app each compile their own copy of the prelude classes,
# so each has its own `String$vtbl`. The object crossing the boundary carries
# the APP's table and the library indexes it with the LIBRARY's number: before
# the fix those were 110 and "no slot at all", which wasm reports as
# "null function or function signature mismatch" from inside SLib$lenOf.
#
# Not a build test. It has to RUN — the module instantiates fine either way,
# and the whole point of 091 is that the failure is at the call.
set -u
cd "$(dirname "$0")" || exit 1
ROOT=$(cd ../.. && pwd)
XCC=${XCC:-$ROOT/bin/osx/xcc-xc}
# ABSOLUTE before the cd below, or a relative $XCC vanishes the moment we move
# into the work dir — and the fallback then reports "library did not build",
# which is a lie about the compiler rather than about the path.
case "$XCC" in /*) ;; *) XCC=$ROOT/$XCC;; esac
[ -x "$XCC" ] || XCC=$ROOT/bin/linux/xcc-xc
command -v node >/dev/null || { echo "091: SKIP (no node)"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cp SLib.xc sapp.xc "$W/" || exit 1
cd "$W" || exit 1
"$XCC" -q -A wasm32 --emit-lib -H "$ROOT" -o libSLib SLib.xc >build.log 2>&1 \
    || { echo "091: FAIL (library did not build)"; sed 's/^/    /' build.log|head -5; exit 1; }
"$XCC" -q -A wasm32 -L . -H "$ROOT" -o sapp sapp.xc >>build.log 2>&1 \
    || { echo "091: FAIL (app did not build)"; sed 's/^/    /' build.log|head -5; exit 1; }
out=$(node sapp.js 2>&1)
echo "$out" | grep -q 'lenOwn 3' || { echo "091: FAIL — library's own object"; echo "$out"|head -3; exit 1; }
echo "$out" | grep -q 'lenOf  6' || { echo "091: FAIL — APP's object across the boundary"; echo "$out"|head -3; exit 1; }
echo "091: PASS (lenOwn 3, lenOf 6 — both vtable directions)"
