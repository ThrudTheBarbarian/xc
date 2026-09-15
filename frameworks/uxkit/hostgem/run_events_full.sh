#!/bin/bash
# run_events_full.sh — broader event-injection coverage: drive the GEM backend through a TABLE row
# selection, TEXT-FIELD focus + typing, and button actions, all headless.  The evkit_a9 client builds
# the widgets and writes an injection script (host_gemd `script` mode plays it); each toolkit callback
# appends an outcome marker.  Assert the markers.  macOS-only.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
UXKit=$(cd "$HERE/.." && pwd)
export UX_GEM_DIR=${UX_GEM_DIR:-${GEM_DIR:-}}
xcc=${XCC:-xcc}
SCRIPT=/tmp/hostgem_script.txt
RESULT=/tmp/hostgem_ev_result.txt
CLOG=/tmp/hostgem_evkit_client.log
rm -f "$SCRIPT" "$RESULT" "$CLOG"

echo "== building host gemd + dylibs =="
bash "$HERE/build_gemd.sh" >/dev/null || { echo "gemd build failed"; exit 1; }
echo "== building the UXKit event-kit client (xcc -A arm64) =="
"$xcc" -A arm64 -I "$UXKit" -L /tmp "$HERE/evkit_a9.xc" -o /tmp/xg_evkit || { echo "client build failed"; exit 1; }

echo "== running gemd (script mode) + the client, playing the injection script =="
UX_GEM_DIR=$UX_GEM_DIR /tmp/xg_hostgemd/host_gemd script 3 >/tmp/hostgem_evkit_gemd.log 2>&1 & GPID=$!
sleep 1.5
UX_CLIENT=1 UX_GEM_DIR=$UX_GEM_DIR DYLD_LIBRARY_PATH=/tmp timeout 12 /tmp/xg_evkit >"$CLOG" 2>&1 & CPID=$!
wait $GPID; kill $CPID 2>/dev/null; wait $CPID 2>/dev/null

echo "== outcome markers =="
cat "$RESULT" 2>/dev/null || echo "(no markers written)"

fail=0
check() { if grep -qxF "$1" "$RESULT" 2>/dev/null; then echo "  ok: $1"; else echo "  MISSING: $1"; fail=1; fi; }
echo "== asserting =="
check "TABLE_ROW 1"      # a table row click reached tableSelectionDidChange
check "TABLE_SEL 2"      # ctrl-click extended it to a 2-row multi-selection
check "FIELD [Hi]"       # focus-by-click + injected keys edited the field
check "MENU_PING"        # a menu title + dropdown item selection fired the item action
check "QUIT"             # a button action fired and stopped the app
if [ $fail = 0 ]; then
    echo "PASS: table selection, field typing, menu selection, and button actions all driven by injection"
    exit 0
else
    echo "FAIL: some part of the event surface did not respond to injection"
    exit 1
fi
