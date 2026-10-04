#!/bin/bash
# run_xtos.sh — a UXKit test on XTOS: built for arm9 and run under qemu (Zynq) on the XTOS
# loader, as a client of the real gemd it starts.  `run_xtos.sh` is the xtos-snapshot gate
# (test_snapshot.xc); `run_xtos.sh native` is xtos-native (test_gem_native.xc, GEM's own
# controls).
# qemu's display plane is 200x120 and gemd gives no window a surface larger than its screen, so the
# layout is halved (-D SNAP_HALF, -D NATIVE_HALF).  The loader is built in a directory of its own (XTOS_BUILD,
# default build-uxkit), with an empty romfs overlay: the program carries the toolkit itself.
# Needs LOADER (build.env), arm-none-eabi-gcc, ld.lld and qemu-system-arm.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
LOADER=${LOADER:-}
[ -d "$LOADER" ] || { echo "== $NAME: skipped (no LOADER in build.env) =="; exit 0; }
command -v qemu-system-arm >/dev/null || { echo "== $NAME: skipped (no qemu-system-arm) =="; exit 0; }
B=${XTOS_BUILD:-build-uxkit}
case "${1:-snapshot}" in
  native) NAME=xtos-native; SRC=test_gem_native.xc; DEFS="-D NATIVE_HALF" ;;
  *)      NAME=xtos-snapshot; SRC=test_snapshot.xc; DEFS="-D SNAP_GEM -D SNAP_HALF" ;;
esac
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
echo "== building the loader's libraries in $B =="
make -C "$LOADER" BUILD="$B" "$B/libGEM.so" "$B/libxtos.so" >"$W/libs.log" 2>&1 || { tail -5 "$W/libs.log"; echo "== $NAME: FAILED (libraries) =="; exit 1; }
echo "== building $SRC (xcc -A arm9) =="
"$xcc" -A arm9 -I "$HERE" -L "$LOADER/$B" $DEFS "$HERE/$SRC" -o "$W/test.so" || { echo "== $NAME: FAILED (build) =="; exit 1; }
mkdir -p "$LOADER/$B/overlay"
echo "== booting XTOS under qemu =="
timeout 900 make -C "$LOADER" BUILD="$B" ROMFS_OVERLAY="$B/overlay" xtcrun XTC_SO="$W/test.so" >"$W/run.log" 2>&1
# the presented frames are ASCII dumps; the test's own lines are what is left
sed -n '/=== running/,$p' "$W/run.log" | grep -avE '^[-*:=. ~+#@%$&]*$' | grep -aE ' ok | FAIL|^PASS|^FAIL|  \('
grep -aq '^PASS' "$W/run.log" || { echo "== $NAME: FAILED =="; exit 1; }
echo "== $NAME: OK =="
