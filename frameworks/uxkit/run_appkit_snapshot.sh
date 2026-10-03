#!/bin/sh
# run_appkit_snapshot.sh -- the `appkit-snapshot` gate: UXWindow.snapshot on macOS, in a live window
# (GL on, native controls realized) and headless (no window shown, no GL).  macOS only.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-snapshot: skipped (not macOS) =="; exit 0 ;; esac
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$here" -D SNAP_APPKIT "$here/test_snapshot.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/test_snapshot" -q
for mode in live headless; do
  echo "== appkit-snapshot: $mode =="
  if [ "$mode" = headless ]; then out=$(UX_SNAP_HEADLESS=1 "$work/test_snapshot"); else out=$("$work/test_snapshot"); fi
  printf '%s\n' "$out"
  printf '%s\n' "$out" | grep -q '^PASS' || { echo "== appkit-snapshot: FAILED ($mode) =="; exit 1; }
done
echo "== appkit-snapshot: OK =="
