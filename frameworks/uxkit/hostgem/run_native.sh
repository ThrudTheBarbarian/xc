#!/bin/bash
# run_native.sh — GEM draws its own controls (the gem-native gate): test_gem_native.xc as a client of a
# real host gemd, its check box, radio buttons, slider, popup and scroll bar GEM objects drawn by the
# AES.  Writes the last picture to /tmp/hostgem_native.ppm.
# macOS-only.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
UXKit=$(cd "$HERE/.." && pwd)
export UX_GEM_DIR=${UX_GEM_DIR:-${GEM_DIR:-}}
[ -d "$UX_GEM_DIR" ] || { echo "== gem-native: skipped (no GEM tree; set GEM_DIR) =="; exit 0; }
xcc=${XCC:-xcc}
SCRIPT=/tmp/hostgem_script.txt
CLOG=/tmp/hostgem_native_client.log
rm -f "$CLOG"
printf 'DELAY 3000\n' > "$SCRIPT" # gemd stays up while the client runs; the verdict is the client's
echo "== building host gemd + dylibs =="
bash "$HERE/build_gemd.sh" >/dev/null || { echo "gemd build failed"; exit 1; }
echo "== building the native-controls client (xcc -A arm64) =="
"$xcc" -A arm64 -I "$UXKit" -L /tmp "$UXKit/test_gem_native.xc" -o /tmp/xg_native || { echo "client build failed"; exit 1; }
echo "== running gemd + the client =="
UX_GEM_DIR=$UX_GEM_DIR /tmp/xg_hostgemd/host_gemd script 3 >/tmp/hostgem_native_gemd.log 2>&1 & GPID=$!
sleep 1.5
UX_CLIENT=1 UX_GEM_DIR=$UX_GEM_DIR UX_SNAP_SAVE=/tmp/hostgem_native.ppm DYLD_LIBRARY_PATH=/tmp timeout 12 /tmp/xg_native >"$CLOG" 2>&1
kill $GPID 2>/dev/null; wait $GPID 2>/dev/null
grep -E 'ok |FAIL|PASS|\(' "$CLOG" | grep -vE '^[-*:=. ~+#@%$&]*$'
grep -q '^PASS' "$CLOG" || { echo "== gem-native: FAILED =="; exit 1; }
echo "== gem-native: OK =="
