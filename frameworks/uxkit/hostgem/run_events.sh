#!/bin/bash
# run_events.sh — the milestone-3 test: inject a synthetic mouse click into the host gemd and prove
# UXKit turns it into a fired button action.  Builds the host gemd + the ev_a9 client (one window, one
# Quit button), runs them together over the POSIX shim, bridges the client's reported button centre
# to the injector, and asserts the client printed EVENT_ACTION_FIRED (its onQuit ran).  macOS-only.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
UXKit=$(cd "$HERE/.." && pwd)
export UX_GEM_DIR=${UX_GEM_DIR:-${GEM_DIR:-}}
xcc=${XCC:-xcc}
CLICK=/tmp/hostgem_click.txt
CLOG=/tmp/hostgem_ev_client.log
RESULT=/tmp/hostgem_ev_result.txt
rm -f "$CLICK" "$CLOG" "$RESULT"

echo "== building host gemd + dylibs =="
bash "$HERE/build_gemd.sh" >/dev/null || { echo "gemd build failed"; exit 1; }
echo "== building the UXKit event-probe client (xcc -A arm64) =="
"$xcc" -A arm64 -I "$UXKit" -L /tmp "$HERE/ev_a9.xc" -o /tmp/xg_ev || { echo "client build failed"; exit 1; }

echo "== running gemd (events mode) + the client, injecting a click =="
UX_GEM_DIR=$UX_GEM_DIR /tmp/xg_hostgemd/host_gemd events 3 >/tmp/hostgem_ev_gemd.log 2>&1 & GPID=$!
sleep 1.5
UX_CLIENT=1 UX_GEM_DIR=$UX_GEM_DIR DYLD_LIBRARY_PATH=/tmp timeout 12 /tmp/xg_ev >"$CLOG" 2>&1 & CPID=$!

# The client writes its button centre to $CLICK directly (stdout is block-buffered, no good for a live
# read); the gemd process (events mode) polls that file and injects the click into /OS/dev/input.
wait $GPID; kill $CPID 2>/dev/null; wait $CPID 2>/dev/null

echo "== client output =="
sed -n '1,20p' "$CLOG"
# The result file is written by onQuit itself (unbuffered), so it is a reliable witness even if the
# client is signalled before a clean exit would flush stdout.
if grep -q 'EVENT_ACTION_FIRED' "$RESULT" 2>/dev/null; then
    echo "PASS: an injected os_event fired the button's action in UXKit"
    exit 0
else
    echo "FAIL: the injected click did not reach the button action"
    exit 1
fi
