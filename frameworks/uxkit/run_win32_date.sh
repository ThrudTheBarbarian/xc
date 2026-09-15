#!/bin/sh
# make win32-date — UXDate.currentDate against a real driver clock, under Wine.
# test_date covers the arithmetic (pure integer maths, no backend); this covers the seam: the
# driver's wall clock, delivered as UTC civil components.  Skips when wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32-date: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-date: compiling for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_date.exe" "$here/test_win32_date.xc" -q 2>/dev/null
echo "== win32-date: launching under Wine =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 45 wine test_win32_date.exe 2>/dev/null)
printf '%s\n' "$got"
if printf '%s\n' "$got" | grep -q '^PASS: currentDate reads the driver clock$'; then
    echo "== win32-date (Wine): PASS — the wall clock reaches UXDate =="
else
    echo "== win32-date (Wine): FAIL =="; exit 1
fi
