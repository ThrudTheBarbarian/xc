#!/bin/bash
# run_gem.sh — milestone 4: the UXKit kitchen-sink in a live, clickable SDL window on macOS, driven by
# the host gemd over the POSIX shim.  Builds the gemd stack + the SDL harness (host_gem_sdl) + the UXKit
# client, then launches the window with the client connected.  Pass `--build-only` to just compile +
# link (CI / headless check) without opening a window.  macOS-only; needs SDL2 (brew install sdl2).
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
UXKit=$(cd "$HERE/.." && pwd)
export UX_GEM_DIR=${UX_GEM_DIR:-${GEM_DIR:-}}
OUT=${OUT:-/tmp/xg_hostgemd}
xcc=${XCC:-xcc}
BUILD_ONLY=0; [ "${1:-}" = "--build-only" ] && BUILD_ONLY=1

command -v pkg-config >/dev/null && pkg-config --exists sdl2 || { echo "SDL2 not found (brew install sdl2)"; exit 1; }
SDL_CFLAGS=$(pkg-config --cflags sdl2); SDL_LIBS=$(pkg-config --libs sdl2)

echo "== building host gemd stack + dylibs =="
bash "$HERE/build_gemd.sh" >/dev/null || { echo "gemd build failed"; exit 1; }

echo "== building the SDL harness (host_gem_sdl) =="
FT_CFLAGS=$(pkg-config --cflags freetype2); FT_LIBS=$(pkg-config --libs freetype2)
cc -std=gnu11 -O0 -g -w -DGEM_XTOS -I"$HERE" -I"$UX_GEM_DIR" -I"$UX_GEM_DIR/gemd" $SDL_CFLAGS $FT_CFLAGS \
   -c "$HERE/host_gem_sdl.c" -o "$OUT/host_gem_sdl.o" || { echo "host_gem_sdl.c failed"; exit 1; }
# link the SDL harness against the gemd objects (everything host_gemd links, minus host_gemd's own main)
GEM_OBJS=$(ls "$OUT"/*.o | grep -vE '/(host_gemd|host_gem_sdl).o$')
cc "$OUT/host_gem_sdl.o" $GEM_OBJS $SDL_LIBS $FT_LIBS -lz -lsqlite3 -lpthread -o "$OUT/host_gem_sdl" \
   || { echo "SDL harness link failed"; exit 1; }
echo "linked: $OUT/host_gem_sdl"

echo "== building the UXKit kitchen-sink client (xcc -A arm64) =="
"$xcc" -A arm64 -I "$UXKit" -L /tmp "$UXKit/ks_a9.xc" -o /tmp/xg_ks || { echo "client build failed"; exit 1; }

if [ "$BUILD_ONLY" = 1 ]; then echo "build-only: OK (run without --build-only to open the window)"; exit 0; fi

echo "== opening the window (close it, or click Quit in the app, to exit) =="
UX_GEM_DIR=$UX_GEM_DIR "$OUT/host_gem_sdl" & SPID=$!
sleep 1.5
UX_CLIENT=1 UX_GEM_DIR=$UX_GEM_DIR DYLD_LIBRARY_PATH=/tmp /tmp/xg_ks >/tmp/hostgem_gem_client.log 2>&1 & CPID=$!
wait $SPID; kill $CPID 2>/dev/null
