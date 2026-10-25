#!/bin/sh
# run_trackmouse.sh — the trackmouse gate: UXView.trackMouse, called from mouseDown, delivers a drag's
# moves and its release to the view on the desktop (test_trackmouse.xc), headless on AppKit and on GTK
# (Homebrew GTK 4).  macOS only; each leg skips when its platform is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
[ "$(uname)" = Darwin ] || { echo "== trackmouse: skipped (not macOS) =="; exit 0; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail=0
cc -I "$here" -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
    "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$here" "$here/test_trackmouse.xc" -Xlinker "$work/libUXAppKit.dylib" \
    -framework Cocoa -framework OpenGL -o "$work/track_appkit" -q 2>/dev/null
out=$(timeout 30 "$work/track_appkit" 2>&1) || true
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q '^PASS' && echo "== trackmouse (appkit): OK ==" || { echo "== trackmouse (appkit): FAIL =="; fail=1; }
if pkg-config --exists gtk4 2>/dev/null; then
    cc -I "$here" -dynamiclib -install_name "$work/libUXGtk.dylib" "$here/libUXGtk.c" \
        $(pkg-config --cflags --libs gtk4) -o "$work/libUXGtk.dylib" 2>/dev/null
    "$xcc" -A arm64 -D UX_TRACK_GTK -I "$here" "$here/test_trackmouse.xc" -Xlinker "$work/libUXGtk.dylib" \
        -o "$work/track_gtk" -q 2>/dev/null
    out=$(timeout 30 "$work/track_gtk" 2>&1 | grep -v Warning) || true
    printf '%s\n' "$out"
    printf '%s\n' "$out" | grep -q '^PASS\|^SKIP' && echo "== trackmouse (gtk): OK ==" || { echo "== trackmouse (gtk): FAIL =="; fail=1; }
fi
exit $fail
