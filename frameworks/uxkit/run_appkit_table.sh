#!/bin/sh
# The AppKit native-table demo — the neutral UXTableView drawn as a real NSTableView.  Shows a
# window with a native, column-headed, alternating-row table; click a row (the label updates via the
# app's tableSelectionDidChange) and scroll the list.  The same datasource drives the GEM object
# tree on arm9.  Nothing in the app is AppKit-aware except the driver.  macOS-only.  Foreground.
set -e
# --auto-quit [ms]: close the demo by itself after a delay, so a sweep can run it
# unattended.  It exits through the SAME path the close box takes, so it still
# prints whatever it prints -- a killed demo reports nothing and is
# indistinguishable from one that crashed.  An XC main() takes no argv, so the
# option lives here and reaches the binary as UX_AUTOQUIT.
case "${1:-}" in
  --auto-quit) UX_AUTOQUIT=${2:-1500}; export UX_AUTOQUIT ;;
esac
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-table: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== appkit-table: building the ObjC shim + the demo for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/demo_appkit_table.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/demo_appkit_table" -q 2>/dev/null

echo "== appkit-table: launching — click a row, scroll the list, then close the window =="
"$work/demo_appkit_table"
echo "== appkit-table: done =="
