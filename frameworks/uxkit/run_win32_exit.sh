#!/bin/sh
# make win32-exit — the app must EXIT when its close box is pressed.
# `make win32` hung on exit and had to be force-quit: the close box arrives as WM_SYSCOMMAND/SC_CLOSE,
# and DefWindowProc turns that into a SENT WM_CLOSE, which never enters the queue nextEvent reads —
# so DefWindowProc destroyed the window itself and the run loop waited for ever.  This presses the
# close box the way a window manager does and asserts run() returns.  Skips when wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32-exit: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-exit: compiling for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_exit.exe" "$here/test_win32_exit.xc" -q 2>/dev/null
echo "== win32-exit: launching under Wine =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 45 wine test_win32_exit.exe 2>/dev/null)
printf '%s\n' "$got"
if printf '%s\n' "$got" | grep -q '^PASS: the app exits when its last window closes$'; then
    echo "== win32-exit (Wine): PASS — the close box quits the app =="
else
    echo "== win32-exit (Wine): FAIL — hung, or never quit =="; exit 1
fi
