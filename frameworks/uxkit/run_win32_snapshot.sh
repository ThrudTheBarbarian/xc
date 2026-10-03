#!/bin/sh
# run_win32_snapshot.sh -- the `win32-snapshot` gate: UXWindow.snapshot on Windows (under Wine): the
# GL frame, the 2-D views over it and the native button, whole or a region.  Skips without wine.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v wine >/dev/null 2>&1 || { echo "== win32-snapshot: skipped (wine absent) =="; exit 0; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
"$xcc" -A win64 -I "$here" -D SNAP_WIN32 -o "$work/test_snapshot.exe" "$here/test_snapshot.xc" -q
(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_snapshot.exe >"$work/out.txt" 2>/dev/null) || true
cat "$work/out.txt"
grep -aq '^PASS' "$work/out.txt" || { echo "== win32-snapshot: FAILED =="; exit 1; }
echo "== win32-snapshot: OK =="
