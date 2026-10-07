#!/bin/sh
# run_rscload.sh — UXRsc, the rsc loader: layout themes, scoped connections, class overrides, top
# objects and awakeFromRsc (test_rscload.xc), on the AppKit driver with no window shown.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== rsc-load: skipped (not macOS) =="; exit 0 ;; esac
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$here" "$here/test_rscload.xc" -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/test_rscload" -q
out=$(timeout 60 "$work/test_rscload" 2>&1) || true
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q '^PASS' || { echo "== rsc-load: FAILED =="; exit 1; }
echo "== rsc-load: OK =="
