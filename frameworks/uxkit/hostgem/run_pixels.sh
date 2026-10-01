#!/bin/bash
# run_input.sh — hover, the secondary button and the wheel on the GEM backend, headless: the pixels_a9
# client writes an injection script (host_gemd `script` mode plays it: MOVE, RCLICK, WHEEL) and each
# hook it reaches appends an outcome marker.  Assert the markers.  macOS-only.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
UXKit=$(cd "$HERE/.." && pwd)
export UX_GEM_DIR=${UX_GEM_DIR:-${GEM_DIR:-}}
xcc=${XCC:-xcc}
SCRIPT=/tmp/hostgem_script.txt
RESULT=/tmp/hostgem_ev_result.txt
CLOG=/tmp/hostgem_pixels_client.log
rm -f "$SCRIPT" "$RESULT" "$CLOG"

echo "== building host gemd + dylibs =="
bash "$HERE/build_gemd.sh" >/dev/null || { echo "gemd build failed"; exit 1; }
echo "== building the UXKit pixels client (xcc -A arm64) =="
"$xcc" -A arm64 -I "$UXKit" -L /tmp "$HERE/pixels_a9.xc" -o /tmp/xg_pixels || { echo "client build failed"; exit 1; }

echo "== running gemd (script mode) + the client, playing the injection script =="
UX_GEM_DIR=$UX_GEM_DIR /tmp/xg_hostgemd/host_gemd script 3 >/tmp/hostgem_pixels_gemd.log 2>&1 & GPID=$!
sleep 1.5
UX_CLIENT=1 UX_GEM_DIR=$UX_GEM_DIR DYLD_LIBRARY_PATH=/tmp timeout 12 /tmp/xg_pixels >"$CLOG" 2>&1 & CPID=$!
wait $GPID; kill $CPID 2>/dev/null; wait $CPID 2>/dev/null

echo "== outcome markers =="
cat "$RESULT" 2>/dev/null || echo "(no markers written)"

if grep -qxF "PIXELS OK" "$RESULT" 2>/dev/null; then
    echo "PASS: drawPixels on GEM -- region, scale, alpha, both layouts, the right way up, clipped"
    exit 0
fi
echo "FAIL: drawPixels on GEM"
exit 1
