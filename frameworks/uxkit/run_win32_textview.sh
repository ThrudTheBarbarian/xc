#!/bin/sh
# run_win32_textview.sh -- UXTextView as a native RichEdit (test_win32_textview.xc), under Wine:
# content as attributed runs, the selection, styles, alignment, typing, emoji, undo and redo.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32-textview: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-textview: compiling for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_textview.exe" "$here/test_win32_textview.xc" -q
echo "== win32-textview: running under Wine =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 180 wine test_win32_textview.exe 2>/dev/null) || true
printf '%s\n' "$got"
printf '%s\n' "$got" | grep -q '^PASS' || { echo "== win32-textview: FAIL =="; exit 1; }
echo "== win32-textview: OK =="
