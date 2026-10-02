#!/bin/sh
# run_win32_icon.sh -- the application icon on Win32 under Wine (UXApplication.setIcon): the taskbar and
# title-bar icon of every window, read back with WM_GETICON.  Skips if wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32-icon: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-icon: compiling test_win32_icon.xc for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_icon.exe" "$here/test_win32_icon.xc" -q 2>/dev/null
echo "== win32-icon: launching under Wine =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_icon.exe 2>/dev/null)
printf '%s\n' "$got"
printf '%s\n' "$got" | grep -q '^PASS: Win32 app icon' || { echo "== win32-icon (Wine): FAIL =="; exit 1; }
echo "== win32-icon (Wine): PASS =="
