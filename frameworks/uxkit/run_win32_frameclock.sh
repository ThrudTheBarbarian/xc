#!/bin/sh
# The app's frame clock (UXApplication.everyTurn) on the Win32 backend, under Wine.  Win32 is the
# blocking-nextEvent shape: the deadline has to be a different call (MsgWaitForMultipleObjects) and
# must return an empty turn when it wins, or the loop spins through its turns in no time at all.
# Gates that turns arrive, that a click posted between them is still dispatched, and that the app
# stops from inside a turn.
#
#   xcc -A win64 -> a real PE .exe; run under Wine.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
srcs="test_win32_frameclock.xc"

if ! command -v wine >/dev/null 2>&1; then echo "== win32-frameclock: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== win32-frameclock: compiling the frame clock on Win32 ($srcs) for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_frameclock.exe" "$here/$srcs" -q 2>/dev/null

echo "== win32-frameclock: launching under Wine (the deadline ends the blocking wait) =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_frameclock.exe 2>/dev/null)
printf '%s\n' "$got"

exp=$(cat "$here/expected_win32_frameclock.out")
if [ "$got" = "$exp" ]; then
    echo "== win32-frameclock (Wine): PASS — the frame clock runs on the blocking backend =="
else
    echo "== win32-frameclock (Wine): FAIL =="
    printf 'want:\n%s\n' "$exp"
    exit 1
fi
