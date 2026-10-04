#!/bin/bash
# run_snapshot.sh — UXWindow.snapshot on the GEM backend (the gem-snapshot gate): test_snapshot.xc as
# a client of a real host gemd, its window read back from its own surface.  GEM has no GL, so the map
# is the GL view's drawn fallback, in the same colour.  macOS-only.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
UXKit=$(cd "$HERE/.." && pwd)
export UX_GEM_DIR=${UX_GEM_DIR:-${GEM_DIR:-}}
[ -d "$UX_GEM_DIR" ] || { echo "== gem-snapshot: skipped (no GEM tree; set GEM_DIR) =="; exit 0; }
xcc=${XCC:-xcc}
SCRIPT=/tmp/hostgem_script.txt
CLOG=/tmp/hostgem_snapshot_client.log
rm -f "$CLOG"
printf 'DELAY 3000\n' > "$SCRIPT" # gemd stays up while the client runs; the verdict is the client's
echo "== building host gemd + dylibs =="
bash "$HERE/build_gemd.sh" >/dev/null || { echo "gemd build failed"; exit 1; }
echo "== building the snapshot client (xcc -A arm64) =="
"$xcc" -A arm64 -I "$UXKit" -L /tmp -D SNAP_GEM "$UXKit/test_snapshot.xc" -o /tmp/xg_snapshot || { echo "client build failed"; exit 1; }
echo "== running gemd + the client =="
UX_GEM_DIR=$UX_GEM_DIR /tmp/xg_hostgemd/host_gemd script 3 >/tmp/hostgem_snapshot_gemd.log 2>&1 & GPID=$!
sleep 1.5
UX_CLIENT=1 UX_GEM_DIR=$UX_GEM_DIR UX_SNAP_SAVE=/tmp/hostgem_snapshot.ppm DYLD_LIBRARY_PATH=/tmp timeout 12 /tmp/xg_snapshot >"$CLOG" 2>&1
kill $GPID 2>/dev/null; wait $GPID 2>/dev/null
grep -E 'ok |FAIL|PASS|\(' "$CLOG" | grep -vE '^[-*:=. ~+#@%$&]*$'
grep -q '^PASS' "$CLOG" || { echo "== gem-snapshot: FAILED =="; exit 1; }
echo "== gem-snapshot: OK =="
