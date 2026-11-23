#!/bin/bash
# uxkit-web-loop.sh — the web framework's driver test, built for wasm32 by the
# shipped compiler at -O0 and -O2, must run: UXApplication.run() blocks on the
# event ring in a worker, the parent pushes a click, the bound action fires.
#
# A pinned local the optimiser removed from a function kept a stale entry in
# the frame list. The back end read its id as 0 and seeded `self` with a frame
# address, so UXWindow.init wrote into its own frame and every web driver gate
# hung (uxkit/037). No fixture reached that shape; this program does. A hang
# is the failure, so each run has a time limit.
#
# Needs node, and frameworks/uxkit beside the compiler; skips without either.
set -u
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
XCC=${XCC:-$ROOT/bin/$XC_PLAT/xcc-xc}
[ -x "$XCC" ] || XCC=$ROOT/bin/linux/xcc-xc
[ -x "$XCC" ] || { echo "FAIL  no shipped compiler (bin/<host>/xcc-xc, or set XCC)"; exit 1; }
UX=$ROOT/../frameworks/uxkit
[ -f "$UX/test_web_loop.xc" ] || { echo "SKIP  no frameworks/uxkit beside the compiler"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP  no node on PATH"; exit 0; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/uxkit-web-loop.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
# A time limit without coreutils' timeout (macOS has none by default).
limit() { perl -e 'alarm shift; exec @ARGV or exit 127' "$@"; }
fail=0
for O in 0 2; do
    if ! "$XCC" -q -O$O -A wasm32 -H "$ROOT" -I "$UX" -o "$TMP/loop$O" "$UX/test_web_loop.xc" 2>"$TMP/err"; then
        echo "FAIL  -O$O: did not build"; sed 's/^/        /' "$TMP/err"; fail=1; continue
    fi
    out=$(limit 60 node "$UX/run_web_loop.mjs" "$TMP/loop$O.js" 2>&1); rc=$?
    if [ $rc -eq 0 ] && printf '%s\n' "$out" | grep -q '^PASS'; then
        echo "PASS  -O$O: run() pumped the ring to a bound action"
    else
        [ $rc -eq 142 ] && why="no answer in 60 s" || why="exit $rc"
        echo "FAIL  -O$O: $why"; printf '%s\n' "$out" | sed 's/^/        /'; fail=1
    fi
done
exit $fail
