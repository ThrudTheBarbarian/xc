#!/bin/sh
# run_appkit_pacing.sh -- the `appkit-pacing` gate: the app's turn on macOS is paced by the window's
# display link (once a refresh, steadily), and a slow tick keeps the timer.  Opens a live window for
# about two seconds.  macOS only.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-pacing: skipped (not macOS) =="; exit 0 ;; esac
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$here" "$here/test_appkit_pacing.xc" -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/test_appkit_pacing" -q
out=$(timeout 30 "$work/test_appkit_pacing") || true
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q '^PASS' || { echo "== appkit-pacing: FAILED =="; exit 1; }
echo "== appkit-pacing: OK =="
