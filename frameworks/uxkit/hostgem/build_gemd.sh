#!/bin/bash
# build_gemd.sh — compile the portable GEM stack (core + gemd server + client) for the host, against
# the POSIX shim, into a static host gemd library.  Milestone 1 of the UXKit-on-host-GEM/SDL port.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GEM=${GEM:-${GEM_DIR:-}}
ROCKS=$GEM/../third_party/Rocks/src
OUT=${OUT:-/tmp/xg_hostgemd}
mkdir -p "$OUT"

FT=$(pkg-config --cflags freetype2)
# -DGEM_XTOS: this IS the XTOS GEM client/server stack (wind_client_stray, gem_send, the surface
# protocol) — just running on macOS over the POSIX shim rather than the kernel.  It is NOT the
# gem_sdl in-process testbed, which is a different platform.
# INSTRUMENT=1 compiles libGEM's draw profiler in (gfx_soft.c, -DINSTRUMENTATION, the same switch
# the gem Makefile spells INSTRUMENT).  Off the board it prints a one-line summary per second to
# STDERR from both halves — client ("cli") and server ("srv") — counting renders, layout, text,
# blits, fills and DAMAGED PIXELS.  That last number is the one to watch when a repaint looks too
# broad: it is what the app actually asked the compositor to take.
CFLAGS="-std=gnu11 -O0 -g -w -Wno-implicit-function-declaration -DGEM_XTOS -DGEM_HOST ${INSTRUMENT:+-DINSTRUMENTATION} -I$HERE -I$GEM -I$GEM/gemd -I$ROCKS -DRSC_NO_STATE_FLAGS -DG_BOX=G_BOX $FT"

SRCS=( "$GEM"/gfx_soft.c "$GEM"/font.c "$GEM"/wm.c "$GEM"/theme.c
       "$GEM"/vdi/*.c "$GEM"/vdi/printers/*.c "$GEM"/aes/*.c
       "$GEM"/gemd/server.c "$GEM"/gemd/route.c "$GEM"/gemd/surface.c "$GEM"/gemclient.c
       "$GEM"/registry.c "$GEM"/xg_settings.c
       "$HERE"/xtos_host.c )

ok=0; fail=0; failed=()
for f in "${SRCS[@]}"; do
    rel=$(echo "$f" | sed "s#$GEM/##; s#$HERE/##; s#/#_#g")
    # redirect the host asset paths at the shared C entry points: theme.c opens via fopen; font.c's
    # font_face_open is renamed so the shim can wrap it (see xtos_host.c).
    extra=""
    case "$f" in
        */theme.c) extra="-Dfopen=xg_fopen" ;;
        */font.c)  extra="-Dfont_face_open=xg_ffo_real" ;;
        */load_fonts.c) extra="-Dopendir=xg_opendir" ;;   # vst_load_fonts scans the (redirected) font dir
    esac
    if cc $CFLAGS $extra -c "$f" -o "$OUT/${rel%.c}.o" 2>"$OUT/err_$rel.txt"; then
        ok=$((ok+1))
    else
        fail=$((fail+1)); failed+=("$rel")
    fi
done
# the Rocks resource engine: aes.h force-included so its enums coincide with ours
if cc $CFLAGS -include "$GEM"/aes/aes.h -c "$ROCKS"/rsc.c -o "$OUT/rsc_engine.o" 2>"$OUT/err_rsc.txt"; then
    ok=$((ok+1)); else fail=$((fail+1)); failed+=("rsc.c"); fi

echo "compiled OK: $ok   failed: $fail"
if [ $fail -gt 0 ]; then printf 'failed: %s\n' "${failed[*]}"; exit 1; fi

# link the headless host gemd harness
cc $CFLAGS -c "$HERE"/host_gemd.c -o "$OUT/host_gemd.o" 2>"$OUT/err_host_gemd.txt" || { echo "host_gemd.c FAILED"; cat "$OUT/err_host_gemd.txt"; exit 1; }
FTLIB=$(pkg-config --libs freetype2)
# -lz for the PDF printer device's Flate streams.  gem_send (gemclient) is used by gemd too, and
# wind_client_stray resolves from aes/window.o.  Exclude host_gem_sdl.o (the M4 SDL harness): it is a
# SEPARATE main built by run_gem.sh into the same $OUT, and pulling it in here both duplicates main()
# and drags in unlinked SDL symbols.
GEMD_OBJS=$(ls "$OUT"/*.o | grep -vE '/host_gem_sdl.o$')
if cc $GEMD_OBJS $FTLIB -lz -lsqlite3 -lpthread -o "$OUT/host_gemd" 2>"$OUT/err_link.txt"; then
    echo "linked: $OUT/host_gemd"
else
    echo "LINK FAILED:"; grep -iE 'undefined|error|duplicate' "$OUT/err_link.txt" | head -20
    exit 1
fi

# The dylibs + dSYMs the UXKit client links (libGEM = the gem stack minus the shim; libxtos = the shim).
GEM_OBJS=$(ls "$OUT"/*.o | grep -vE '/(host_gemd|host_gem_sdl|xtos_host).o$')
cc -dynamiclib $GEM_OBJS $FTLIB -lz -lsqlite3 -undefined dynamic_lookup -o /tmp/libGEM.dylib 2>/dev/null && dsymutil /tmp/libGEM.dylib 2>/dev/null
cc -dynamiclib "$OUT/xtos_host.o" -undefined dynamic_lookup -o /tmp/libxtos.dylib 2>/dev/null && dsymutil /tmp/libxtos.dylib 2>/dev/null
echo "dylibs: /tmp/libGEM.dylib /tmp/libxtos.dylib (+ dSYMs)"
