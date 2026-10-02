#!/bin/sh
# run_appkit_savepanel.sh -- the drawn save panel (UXFilePanel in save mode) on AppKit, headless,
# over a real folder listed by ux_posix_fs.h.  The same test runs on Linux: run_gtk_linux.sh test_savepanel.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-savepanel: skipped (not macOS) =="; exit 0 ;; esac
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== appkit-savepanel: building the shim + the test =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
    "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$here" "$here/test_savepanel.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/test_savepanel" -q 2>/dev/null
echo "== appkit-savepanel: running =="
out=$("$work/test_savepanel")
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q '^PASS' || { echo "== appkit-savepanel: FAIL =="; exit 1; }
echo "== appkit-savepanel: PASS =="
