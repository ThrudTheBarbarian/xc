#!/bin/sh
# Spike 1 (Xtg multi-host) — the first native driver against a real host toolkit.
# A minimal Win32 driver, written in xtc, opens a real window and routes paint
# and click through the neutral XGView/XGContext code path:
#   HWND            = the opaque handle
#   GWLP_USERDATA   = the reverse map (handle -> XGView front object)
#   WndProc         = the per-platform driver
#   WM_PAINT   -> reverse map -> XGView.drawRect override -> XGContext.fillRect (GDI)
#   WM_LBUTTON -> reverse map -> XGView.mouseDown override
# See Rocks/doc/XTG-MULTIPLATFORM.md §10 (Spike 1). Win32 is the first driver
# because it is reachable under Wine, pure C ABI, no Objective-C bridge.
#
# Headless-deterministic: the app forces a paint (InvalidateRect/UpdateWindow)
# and injects a click (PostMessage WM_LBUTTONDOWN) itself, so no display or human
# is needed; the overrides print sentinels diffed against expected.out.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
xtc="$root/bin/osx/xcc"
exp="$(cat "$here/expected.out")"

if ! { command -v wine >/dev/null 2>&1; }; then
    echo "== win64: skipped (wine absent) =="; exit 0
fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
"$xtc" -H "$root" -A win64 -o "$work/spike1.exe" "$here/spike1_win32.xc" -q 2>/dev/null
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine spike1.exe 2>/dev/null)
if [ "$got" = "$exp" ]; then echo "== win64 (Wine): PASS =="; exit 0
else echo "== win64 (Wine): FAIL =="; printf 'want:\n%s\ngot:\n%s\n' "$exp" "$got"; exit 1; fi
