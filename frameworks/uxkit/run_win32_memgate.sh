#!/bin/sh
# The per-backend memory gate for Win32 (doc/XTG-MULTIPLATFORM.md §10), under Wine.  Opens and
# closes N forms (window + content view + button + text field) in a loop and asserts BOTH the
# driver's native-object counter AND the heap baseline return to zero — on the close() path and
# the dealloc path.  The Win32 instance of the gate the GEM backend passes.  Skips if wine absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
srcs="test_win32_memgate.xc"

if ! command -v wine >/dev/null 2>&1; then echo "== win32-memgate: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== win32-memgate: compiling the §10 gate ($srcs) for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_memgate.exe" "$here/$srcs" -q 2>/dev/null

echo "== win32-memgate: launching under Wine (open/close N forms, check both baselines) =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_memgate.exe 2>/dev/null)
printf '%s\n' "$got"

exp=$(cat "$here/expected_win32_memgate.out")
if [ "$got" = "$exp" ]; then
    echo "== win32-memgate (Wine): PASS — no native or heap leak on either teardown path =="
else
    echo "== win32-memgate (Wine): FAIL =="
    printf 'want:\n%s\n' "$exp"
    exit 1
fi
