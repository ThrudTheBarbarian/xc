#!/bin/bash
# uxkit-web-wat.sh — the web framework's driver test compiled for wasm32 by both
# compilers must give the same WAT.
#
# A pinned local the optimiser removed from a function kept a stale entry in
# the frame list. The reference skipped it; the shipped back end read its id as
# 0 and seeded `self` with a frame address, so UXWindow.init wrote into its own
# frame and every web driver gate hung (uxkit/037). No fixture reached that
# shape; this program does.
set -u
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
BIN=$ROOT/bin/$XC_PLAT; [ -x "$BIN/xcc" ] || BIN=$ROOT/bin/linux
UX=$ROOT/../frameworks/uxkit
[ -f "$UX/test_web_loop.xc" ] || { echo "SKIP  no frameworks/uxkit beside the compiler"; exit 0; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/uxkit-web-wat.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
fail=0
for O in 0 2; do
    for C in xcc xcc-xc; do
        ( cd "$UX" && "$BIN/$C" -q -O$O -A wasm32 -H "$ROOT" -I . -S -o "$TMP/$C.wat" test_web_loop.xc ) \
            2>"$TMP/err" || { echo "FAIL  -O$O $C: did not build"; sed 's/^/        /' "$TMP/err"; fail=1; continue 2; }
    done
    if cmp -s "$TMP/xcc.wat" "$TMP/xcc-xc.wat"; then echo "PASS  -O$O: the two compilers' WAT agree"
    else echo "FAIL  -O$O: WAT differs ($(diff "$TMP/xcc.wat" "$TMP/xcc-xc.wat" | grep -c '^[<>]') lines)"; fail=1; fi
done
exit $fail
