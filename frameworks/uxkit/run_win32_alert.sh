#!/bin/sh
# Modal alerts on the Win32 backend, under Wine.  UXAlert is neutral (the model); the driver pops
# a native MessageBox and maps the result back to the neutral 1-based button index.  A WH_CBT hook
# dismisses the box deterministically so the modal call returns headlessly.  Skips if wine absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
srcs="test_win32_alert.xc"
if ! command -v wine >/dev/null 2>&1; then echo "== win32-alert: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-alert: compiling modal alerts on Win32 ($srcs) for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_alert.exe" "$here/$srcs" -q 2>/dev/null
echo "== win32-alert: launching under Wine (MessageBox result -> neutral button index) =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_alert.exe 2>/dev/null)
printf '%s\n' "$got"
exp=$(cat "$here/expected_win32_alert.out")
if [ "$got" = "$exp" ]; then echo "== win32-alert (Wine): PASS — modal alerts on a second backend =="
else echo "== win32-alert (Wine): FAIL =="; printf 'want:\n%s\n' "$exp"; exit 1; fi
