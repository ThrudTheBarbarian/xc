#!/bin/sh
# Menus on the Win32 backend, under Wine.  The neutral app-level UXMenuBar becomes a per-window
# HMENU; a menu pick fires WM_COMMAND(id), which the driver decodes to a neutral UXEventMenuSelect
# and UXApplication routes to the bound method — the same path GEM takes from MN_SELECTED.  The
# demo injects two picks (File>Open, Edit>Cut) through the real queue.  Skips if wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
srcs="test_win32_menu.xc"

if ! command -v wine >/dev/null 2>&1; then echo "== win32-menu: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== win32-menu: compiling menus on Win32 ($srcs) for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_menu.exe" "$here/$srcs" -q 2>/dev/null

echo "== win32-menu: launching under Wine (app-level menu -> per-window HMENU -> WM_COMMAND) =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_menu.exe 2>/dev/null)
printf '%s\n' "$got"

exp=$(cat "$here/expected_win32_menu.out")
if [ "$got" = "$exp" ]; then
    echo "== win32-menu (Wine): PASS — menus route to bound methods on a second backend =="
else
    echo "== win32-menu (Wine): FAIL =="
    printf 'want:\n%s\n' "$exp"
    exit 1
fi
