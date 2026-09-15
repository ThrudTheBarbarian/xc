#!/bin/sh
# make appkit-outline — bug 020 regression guard: a table/outline's OWN internal scroll view must not
# be realized as a native NSScrollView on top of the NSOutlineView, stealing its clicks and hiding its
# selection.  Checks the control COUNT (one, not two) and that a disclosure click still expands.
#
# It had no runner and no make target — the one test in the tree nothing ran, which for a regression
# guard is the same as not having it.  macOS-only.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-outline: skipped (not macOS) =="; exit 0 ;; esac
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== appkit-outline: building the ObjC shim + the test for arm64 =="
# A real dylib with an install_name, NOT a bare .o: xcc's -q linker references a -Xlinker input by
# name at load time, so an MH_OBJECT is unloadable and a relative .o path resolves against whatever
# the cwd happens to be — which is why this ran at all the first time (a stale .o in the repo).
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
    "$here/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_appkit_outline.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/test_appkit_outline" -q 2>/dev/null
echo "== appkit-outline: running =="
"$work/test_appkit_outline"
