#!/bin/sh
# The neutral RUN LOOP on the Win32 backend, under Wine.  test_win32_real ran the neutral view
# layer but drove clicks by hand; this runs the whole app under UXApplication.run() — the SAME
# loop the GEM app uses — pumping the REAL Win32 message queue.  A posted WM_LBUTTONDOWN travels
# driver.nextEvent (GetMessage -> decode) -> UXApplication.dispatchEvent -> the window ->
# UXView.mouseDown; a posted WM_QUIT ends the loop.  Nothing in the app is Win32-aware except
# selecting the backend and the one line that simulates the OS delivering a click.
#
# Headless-deterministic: it checks the sentinels and skips cleanly when wine is absent.
#
#   xcc -A win64 -> a real PE .exe; run under Wine.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
srcs="test_win32_loop.xc"

if ! command -v wine >/dev/null 2>&1; then echo "== win32-loop: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== win32-loop: compiling UXApplication.run() on Win32 ($srcs) for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_loop.exe" "$here/$srcs" -q 2>/dev/null

echo "== win32-loop: launching under Wine (the neutral run loop pumps the real Win32 queue) =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_loop.exe 2>/dev/null)
printf '%s\n' "$got"

exp=$(cat "$here/expected_win32_loop.out")
if [ "$got" = "$exp" ]; then
    echo "== win32-loop (Wine): PASS — the neutral RUN LOOP runs on a second backend =="
else
    echo "== win32-loop (Wine): FAIL =="
    printf 'want:\n%s\n' "$exp"
    exit 1
fi
