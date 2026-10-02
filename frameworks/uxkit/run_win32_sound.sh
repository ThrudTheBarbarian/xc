#!/bin/sh
# run_win32_sound.sh -- sound on Win32 under Wine (UXSound.play): one waveOut stream per sound, two
# overlapping, both finishing and closed.  Skips if wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32-sound: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-sound: compiling test_win32_sound.xc for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_sound.exe" "$here/test_win32_sound.xc" -q 2>/dev/null
echo "== win32-sound: launching under Wine =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_sound.exe 2>/dev/null)
printf '%s\n' "$got"
printf '%s\n' "$got" | grep -q '^PASS: sound on Win32' || { echo "== win32-sound (Wine): FAIL =="; exit 1; }
echo "== win32-sound (Wine): PASS =="
