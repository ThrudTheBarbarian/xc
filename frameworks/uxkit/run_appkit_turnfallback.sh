#!/bin/sh
# run_appkit_turnfallback.sh -- the `appkit-turnfallback` gate: with the turn's display link stopped
# (as a sleeping display or a covered window stops it), the app's turn keeps coming from the driver's
# backup timer.  Opens a live window for about a second.  macOS only.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-turnfallback: skipped (not macOS) =="; exit 0 ;; esac
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$here" "$here/test_appkit_turn_fallback.xc" -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/test_appkit_turn_fallback" -q
out=$(timeout 30 "$work/test_appkit_turn_fallback") || true
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q '^PASS' || { echo "== appkit-turnfallback: FAILED =="; exit 1; }
echo "== appkit-turnfallback: OK =="
