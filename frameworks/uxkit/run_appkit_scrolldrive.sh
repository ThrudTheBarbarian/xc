#!/bin/sh
# make appkit-scrolldrive — the toolkit must be able to scroll a native NSScrollView from code.
# scrollsNatively() is true here, and UXScrollView used to answer that by doing nothing, so
# programmatic scrolling was a silent no-op.  Reads the clip view back.  macOS-only.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-scrolldrive: skipped (not macOS) =="; exit 0 ;; esac
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== appkit-scrolldrive: building the ObjC shim + the test for arm64 =="
# A real dylib with an install_name, NOT a bare .o: xcc's -q linker references a -Xlinker input by
# name at load time, so an MH_OBJECT is unloadable and a relative .o path resolves against whatever
# the cwd happens to be — which is why this ran at all the first time (a stale .o in the repo).
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
    "$here/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_appkit_scrolldrive.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/test_appkit_scrolldrive" -q 2>/dev/null
echo "== appkit-scrolldrive: running =="
"$work/test_appkit_scrolldrive"
