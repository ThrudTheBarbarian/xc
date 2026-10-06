#!/bin/sh
# run_win32_dnd.sh -- drags, drops, context menus, the drag line, the minimum size and late titles
# on Win32 (test_win32_dnd.xc), under Wine.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32-dnd: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-dnd: compiling for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_dnd.exe" "$here/test_win32_dnd.xc" -q
echo "== win32-dnd: running under Wine =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 60 wine test_win32_dnd.exe 2>/dev/null) || true
printf '%s\n' "$got"
printf '%s\n' "$got" | grep -q '^PASS' || { echo "== win32-dnd: FAIL =="; exit 1; }
echo "== win32-dnd: OK =="
