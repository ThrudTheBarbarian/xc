#!/bin/bash
# dwarf-diff.sh — the two DWARF type importers must agree, byte for byte.
# =================================================================
#
# `#import <lib>` against a library THIS compiler did not build reads that
# library's own DWARF for its types. The layouts are taken VERBATIM — a
# hand-guessed `sizeof(theme)` would smash the heap, because it is 19502 bytes
# — so "the two compilers agree" is not a nicety here, it is the property that
# makes an imported C type safe to use at all.
#
# The port had no reader (uxkit bug 034-D); this is what stops it drifting from
# the reference's now that it does. Both compilers build the same probe against
# the same libraries and print the reconstructed sizes; the outputs are
# compared. A size that differs by ONE byte is a struct whose fields are at
# different offsets, which is a wrong pointer rather than a wrong number.
#
#   bash selfhost/tools/dwarf-diff.sh
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc" ] || BIN=bin/linux
WORK=${TMPDIR:-/tmp}/dwarfdiff.$$
mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT

# ── Mach-O: a clang-built dylib whose DWARF lives in a sibling .dSYM ──────
# The host case, and the one a developer here hits first. Darwin's linker
# leaves the DWARF in the object files plus a debug map; dsymutil gathers it
# into the .dSYM, so the dylib itself carries NO __debug_info and a reader that
# only looks inside it finds a library with no types.
machoCase() {
    command -v clang >/dev/null && command -v dsymutil >/dev/null || {
        echo "  SKIP  Mach-O case (no clang/dsymutil) — NOT counted as matching"; return 0; }
    mkdir -p "$WORK/mo"
    cat > "$WORK/mo/clib.c" <<'EOF'
#include <stdint.h>
typedef struct { int32_t x; int32_t y; } CPoint;
typedef struct { CPoint origin; int16_t w; char tag; int64_t id; } CRect;
int32_t crect_area(CRect *r) { return (int32_t)(r->w * r->w); }
EOF
    ( cd "$WORK/mo" && clang -g -c clib.c -o clib.o >/dev/null 2>&1       && clang -g -dynamiclib -o libclib.dylib clib.o >/dev/null 2>&1       && dsymutil libclib.dylib >/dev/null 2>&1 ) || {
        echo "  SKIP  Mach-O case (could not build the probe dylib)"; return 0; }
    cat > "$WORK/mo/probe.xc" <<'EOF'
#import "Stdio.xc"
#import <clib>
i32 main(void) {
  CRect r;
  r.w = (i16)6;
  Stdio.printf("CPoint=%lu CRect=%lu area=%ld\n",
               (u32)sizeof(CPoint), (u32)sizeof(CRect), crect_area(&r));
  return (i32)0;
}
EOF
    for c in xcc xcc-xc; do
        "$BIN/$c" -q -A arm64 -H . -L "$WORK/mo" -o "$WORK/mo/$c.bin"             "$WORK/mo/probe.xc" >"$WORK/mo/$c.log" 2>&1 || {
            echo "--- Mach-O: $c could not build the probe:"
            grep -a error "$WORK/mo/$c.log" | head -2; return 1; }
        # RUN it: the types can be right while the LC_LOAD_DYLIB that claims the
        # import is missing, and that only shows at launch.
        # From the dylib's own directory, and with it on the search path: the
        # two linkers spell the install name differently (@rpath vs a bare
        # name) and neither spelling is what is under test here.
        ( cd "$WORK/mo" && DYLD_LIBRARY_PATH="$WORK/mo" ./$c.bin ) > "$WORK/mo/$c.out" 2>&1 || {
            echo "--- Mach-O: $c built but would not run:"
            head -2 "$WORK/mo/$c.out"; return 1; }
    done
    if cmp -s "$WORK/mo/xcc.out" "$WORK/mo/xcc-xc.out"; then
        echo "--- dwarf-diff [Mach-O/.dSYM]: identical  [$(cat "$WORK/mo/xcc.out")]"
        return 0
    fi
    echo "--- dwarf-diff [Mach-O/.dSYM]: DIFFER"
    echo "  reference: $(cat "$WORK/mo/xcc.out")"
    echo "  port     : $(cat "$WORK/mo/xcc-xc.out")"
    return 1
}

. "$(dirname "$0")/arm9-sysroot.sh"
# The loader's GEM tree is the only C library in reach that carries DWARF and
# real aggregate types. Say so rather than passing when there is nothing to read.
[ -x "$BIN/xcc-xc" ] || { echo "!!! $BIN/xcc-xc missing — run 'make production'"; exit 1; }

rc=0
machoCase || rc=1

GEMDIR="${GEMLIB:-}"
if [ ! -f "$GEMDIR/libGEM.so" ]; then
    echo "  SKIP  ELF case (no $GEMDIR/libGEM.so) — NOT counted as matching"
    exit $rc
fi

cat > "$WORK/probe.xc" <<'EOF'
#import "Stdio.xc"
#import <GEM>
#import <xtos>
// Every named aggregate the binding header says comes through the import.
i32 main(void) {
  Stdio.printf("OBJECT=%lu theme=%lu gfx_surface=%lu os_fbinfo=%lu\n",
    (u32)sizeof(OBJECT), (u32)sizeof(theme),
    (u32)sizeof(gfx_surface), (u32)sizeof(os_fbinfo));
  return (i32)0;
}
EOF

L=(-L "$GEMDIR")
[ -n "${ARM9_SYSROOT:-}" ] && L+=(-L "$ARM9_SYSROOT")

fail=0
for c in xcc xcc-xc; do
    if ! "$BIN/$c" -q -A arm64 -H . "${L[@]}" -o "$WORK/$c.bin" "$WORK/probe.xc" \
         >"$WORK/$c.log" 2>&1; then
        echo "--- $c could not build the probe:"; grep -a error "$WORK/$c.log" | head -3
        fail=1
    fi
done
[ "$fail" -eq 0 ] || { echo "--- dwarf-diff: BROKEN (a compiler could not build the probe)"; exit 1; }

"$WORK/xcc.bin"    > "$WORK/ref.out"  2>/dev/null
"$WORK/xcc-xc.bin" > "$WORK/port.out" 2>/dev/null
if [ ! -s "$WORK/ref.out" ]; then
    echo "!!! the ORACLE printed nothing — NOTHING was compared"; exit 1
fi
elffail=0
if cmp -s "$WORK/ref.out" "$WORK/port.out"; then
    echo "--- dwarf-diff [ELF]: identical  [$(cat "$WORK/ref.out")]"
else
    echo "--- dwarf-diff [ELF]: DIFFER"
    echo "  reference: $(cat "$WORK/ref.out")"
    echo "  port     : $(cat "$WORK/port.out")"
    elffail=1
fi

# all-diff reads harnesses by their "pass=N fail=M" line and calls anything
# without one BROKEN. This one reported `identical` twice and nothing else, so
# a run in which BOTH probes agreed was tabulated as a harness that did not
# run — a green result presented as a red one, which is the same failure of
# trust as the reverse. Two probes, so two comparisons.
mopass=$(( 1 - rc )); elfpass=$(( 1 - elffail ))
echo "--- dwarf-diff: pass=$(( mopass + elfpass )) fail=$(( rc + elffail )) ---"
[ $(( rc + elffail )) -eq 0 ] || exit 1
exit 0
