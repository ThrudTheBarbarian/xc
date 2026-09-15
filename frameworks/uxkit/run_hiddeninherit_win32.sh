#!/bin/sh
# run_hiddeninherit_win32.sh — the Win32 half of the hidden-inheritance gate.
# Win32 hides through ShowWindow rather than a shim call, so it is a genuinely
# different path to the same rule and worth its own run.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v "$xcc" >/dev/null 2>&1 || { echo "== hiddeninherit-win32: no compiler; set XCC =="; exit 2; }
command -v wine >/dev/null 2>&1 || { echo "== hiddeninherit-win32: skipped (no wine) =="; exit 0; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
"$xcc" -A win64 -I "$here" "$here/test_hiddeninherit_win32.xc" -o "$work/hi_win.exe" -q
out=$(cd "$work" && WINEDEBUG=-all timeout 60 wine hi_win.exe 2>/dev/null) || true
echo "$out" | tail -3
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== hiddeninherit-win32: FAILED =="; exit 1; }
echo "== hiddeninherit-win32: OK =="
