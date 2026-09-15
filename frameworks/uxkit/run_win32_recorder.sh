#!/bin/sh
# make win32-recorder — capture the event stream and replay it into a live UI, under Wine.
# test_eventrecorder covers the model; this drives the real kitchen-sink Recorder window through
# UXApplication's event tap and replays through the window's dispatch.  The proof is state: a row
# selected and a box toggled by hand, undone, then put back by replay alone.  Skips without wine.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32-recorder: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-recorder: compiling for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_recorder.exe" "$here/test_win32_recorder.xc" -q 2>/dev/null
echo "== win32-recorder: launching under Wine =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 60 wine test_win32_recorder.exe 2>/dev/null)
printf '%s\n' "$got"
if printf '%s\n' "$got" | grep -q '^PASS: capture through the tap, replay through dispatch$'; then
    echo "== win32-recorder (Wine): PASS — record and replay drive the real widgets =="
else
    echo "== win32-recorder (Wine): FAIL =="; exit 1
fi
