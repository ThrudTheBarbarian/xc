#!/bin/sh
# The AppKit native-table demo — the neutral UXTableView drawn as a real NSTableView.  Shows a
# window with a native, column-headed, alternating-row table; click a row (the label updates via the
# app's tableSelectionDidChange) and scroll the list.  The same datasource drives the GEM object
# tree on arm9.  Nothing in the app is AppKit-aware except the driver.  macOS-only.  Foreground.
set -e
# The demo closes ITSELF after a moment (see demo_autoquit.xc), so a run cannot
# camp on the screen and hold the keyboard focus.  It exits through the SAME path
# the close box takes, so it still prints whatever it prints -- a killed demo
# reports nothing and is indistinguishable from one that crashed.
#
#   --stay           keep the window up until you close it (what poking wants)
#   --auto-quit [ms] stay self-closing, with a different delay
#
# An XC main() takes no argv, so the options live here and reach the binary as
# UX_AUTOQUIT.
case "${1:-}" in
  --stay)      UX_AUTOQUIT=0; export UX_AUTOQUIT ;;
  --auto-quit) UX_AUTOQUIT=${2:-1500}; export UX_AUTOQUIT ;;
esac
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-table: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== appkit-table: building the ObjC shim + the demo for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/demo_appkit_table.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/demo_appkit_table" -q 2>/dev/null

echo "== appkit-table: launching (self-closing; --stay to keep it up) =="
"$work/demo_appkit_table"
echo "== appkit-table: done =="
