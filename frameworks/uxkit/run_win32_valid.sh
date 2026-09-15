#!/bin/sh
# Per-character field validation on the Win32 backend, under Wine.  A "99999" field accepts only
# digits: typing "1a2b3" yields "123", letters rejected keystroke-by-keystroke by the driver's
# edit engine (the same alphabet GEM's objc_edit enforces).  Skips if wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
srcs="test_win32_valid.xc"
if ! command -v wine >/dev/null 2>&1; then echo "== win32-valid: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-valid: compiling field validation on Win32 ($srcs) for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_valid.exe" "$here/$srcs" -q 2>/dev/null
echo "== win32-valid: launching under Wine (a digits-only field rejects letters) =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_valid.exe 2>/dev/null)
printf '%s\n' "$got"
exp=$(cat "$here/expected_win32_valid.out")
if [ "$got" = "$exp" ]; then echo "== win32-valid (Wine): PASS — per-character validation on a second backend =="
else echo "== win32-valid (Wine): FAIL =="; printf 'want:\n%s\n' "$exp"; exit 1; fi
