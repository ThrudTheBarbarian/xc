#!/bin/sh
# Build the scroll demo normally, then run it under GUARD MALLOC so a heap overflow / use-after-free
# faults AT the offending access (with a precise stack) instead of later in AppKit.  Drag the window
# smaller to reproduce the resize crash.  macOS-only.
set -e
# --auto-quit [ms]: as in run_appkit_scroll.sh.  This runs the SAME demo binary,
# so it needs the same option -- otherwise a sweep hangs here instead.  Guard
# Malloc makes everything slower, hence the larger default.
case "${1:-}" in
  --auto-quit) UX_AUTOQUIT=${2:-4000}; export UX_AUTOQUIT ;;
esac
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== building (no guard malloc during build) =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/demo_appkit_scroll.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/demo_appkit_scroll" -q 2>/dev/null

echo "== launching under guard malloc — drag the window SMALLER to reproduce the crash =="
MallocScribble=1 DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib "$work/demo_appkit_scroll"
echo "== exited =="
