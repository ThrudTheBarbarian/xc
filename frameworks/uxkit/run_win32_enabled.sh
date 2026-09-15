#!/bin/sh
# Enabled/disabled controls on the Win32 backend, under Wine.  A disabled control does not fire
# (UXControl.mouseDown checks isEnabled) — the same neutral rule on every backend.  A button is
# clicked while disabled (no fire), then setEnabled round-trips.  Skips if wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
srcs="test_win32_enabled.xc"
if ! command -v wine >/dev/null 2>&1; then echo "== win32-enabled: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-enabled: compiling enabled/disabled controls on Win32 ($srcs) for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_enabled.exe" "$here/$srcs" -q 2>/dev/null
echo "== win32-enabled: launching under Wine (a disabled control does not fire) =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_enabled.exe 2>/dev/null)
printf '%s\n' "$got"
exp=$(cat "$here/expected_win32_enabled.out")
if [ "$got" = "$exp" ]; then echo "== win32-enabled (Wine): PASS — disabled controls inert on a second backend =="
else echo "== win32-enabled (Wine): FAIL =="; printf 'want:\n%s\n' "$exp"; exit 1; fi
