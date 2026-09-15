#!/bin/sh
# make win32-settings — UXKeyValueStore against a REAL settings store, under Wine.
#
# Two runs of the same exe: the first writes, the second (a fresh process, nothing in memory) must
# read it all back.  That is the whole point — the store used to be memory only, so every value an
# app "saved" was lost on quit.  Skips when wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32-settings: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-settings: compiling for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_settings.exe" "$here/test_win32_settings.xc" -q 2>/dev/null

# Its own Wine prefix, so the test writes to a THROWAWAY %APPDATA% and a stale UXKit.ini from an
# earlier run can never make a broken write pass look like a working read pass.
export WINEPREFIX="$work/wine"
export WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;"
timeout 60 wine wineboot -i >/dev/null 2>&1 || true

echo "== win32-settings: pass 1 (write) =="
(cd "$work" && UX_SETTINGS_PASS=write timeout 45 wine test_win32_settings.exe 2>/dev/null)

echo "== win32-settings: pass 2 (a fresh process reads it back) =="
got=$(cd "$work" && UX_SETTINGS_PASS=read timeout 45 wine test_win32_settings.exe 2>/dev/null)
printf '%s\n' "$got"
if printf '%s\n' "$got" | grep -q '^PASS: settings persist across processes$'; then
    echo "== win32-settings (Wine): PASS — settings outlive the process =="
else
    echo "== win32-settings (Wine): FAIL =="; exit 1
fi
