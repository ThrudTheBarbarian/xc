#!/bin/sh
# run_busy.sh — the busy gate (`busy`): UXApplication.beginBusy / endBusy reach the platform and nest
# (test_busy.xc).  macOS: the NSProcessInfo activity, headless.  Windows: power throttling, read back
# with GetProcessInformation, which needs Windows 11; Wine and Windows 10 report SKIP.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail=0
check() { # leg output
    printf '%s\n' "$2"
    if printf '%s\n' "$2" | grep -q '^PASS\|^SKIP'; then echo "== busy ($1): OK =="; else echo "== busy ($1): FAIL =="; fail=1; fi
}
if [ "$(uname)" = Darwin ]; then
    cc -I "$here" -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
        "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
    "$xcc" -A arm64 -I "$here" "$here/test_busy.xc" -Xlinker "$work/libUXAppKit.dylib" \
        -framework Cocoa -framework OpenGL -o "$work/busy" -q 2>/dev/null
    check appkit "$("$work/busy")"
fi
if command -v wine >/dev/null 2>&1; then
    "$xcc" -A win64 -I "$here" "$here/test_busy.xc" -o "$work/busy.exe" -q 2>/dev/null
    check win32 "$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine busy.exe 2>/dev/null | tr -d '\r')"
fi
exit $fail
