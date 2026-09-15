#!/bin/sh
# Hidden controls on the Win32 backend, under Wine.  A hidden view is neither drawn nor hit — the
# driver's paint walk and hit test both skip a node with the hidden flag set (the neutral setHidden
# rides on it).  A button is clicked visible (fires), hidden (ignored), visible (fires): 1->1->2.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
srcs="test_win32_hidden.xc"
if ! command -v wine >/dev/null 2>&1; then echo "== win32-hidden: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-hidden: compiling hidden controls on Win32 ($srcs) for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_hidden.exe" "$here/$srcs" -q 2>/dev/null
echo "== win32-hidden: launching under Wine (a hidden control is not hit) =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_hidden.exe 2>/dev/null)
printf '%s\n' "$got"
exp=$(cat "$here/expected_win32_hidden.out")
if [ "$got" = "$exp" ]; then echo "== win32-hidden (Wine): PASS — hidden controls inert on a second backend =="
else echo "== win32-hidden (Wine): FAIL =="; printf 'want:\n%s\n' "$exp"; exit 1; fi
