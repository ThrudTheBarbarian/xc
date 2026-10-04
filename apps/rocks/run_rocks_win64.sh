#!/bin/sh
# run_rocks_win64.sh -- the `rocks-win64` gate: Rocks itself, built for Windows and run under Wine:
# its window built and wired (the PASS line the app prints once it is up).  Skips without Wine.
set -e
here=$(cd "$(dirname "$0")" && pwd)
ux="$here/../../frameworks/uxkit"
xcc=${XCC:-xcc}
command -v wine >/dev/null 2>&1 || { echo "== rocks-win64: skipped (no wine) =="; exit 0; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== rocks-win64: building =="
"$xcc" -A win64 -I "$ux" -I "$here/xc" "$here/xc/rocks_main.xc" -o "$work/rocks.exe" -q
echo "== rocks-win64: running under Wine (the app quits itself after 8 s) =="
# To a FILE, not a pipe: Wine's helper processes inherit the pipe and keep it open after the app is
# stopped, so a reader waiting for its end would wait forever.
# UX_AUTOQUIT ends the app by the path its own quit takes: a Wine process killed from outside leaves
# its winedevice helpers running for good.  The timeout is only a backstop.
(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d" UX_AUTOQUIT=8000 timeout 60 wine rocks.exe >"$work/out.txt" 2>&1) || true
pkill -f 'rocks.exe' 2>/dev/null || true
out=$(grep -aE '^(PASS|FAIL|SKIP)' "$work/out.txt" | head -1)
echo "$out"
echo "$out" | grep -q '^PASS' || { echo "== rocks-win64: FAILED =="; exit 1; }
echo "== rocks-win64: OK =="
