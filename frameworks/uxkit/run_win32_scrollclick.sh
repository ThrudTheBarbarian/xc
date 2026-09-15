#!/bin/sh
# make win32-scrollclick — a click inside a native scroll container must reach the view it lands on.
# The UXScroll32 child owns the click (the canvas never sees it), so the child proc translates it back
# into the parent's client space — plus the bar position — and posts it on.  Clicks a marker in the
# document unscrolled and again after a 40px scroll; both must land on it.  Skips when wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32-scrollclick: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-scrollclick: compiling for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_scrollclick.exe" "$here/test_win32_scrollclick.xc" -q 2>/dev/null
echo "== win32-scrollclick: launching under Wine =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_scrollclick.exe 2>/dev/null)
printf '%s\n' "$got"
if printf '%s\n' "$got" | grep -q '^scrollClickRouted=1$'; then
    echo "== win32-scrollclick (Wine): PASS — clicks reach the scrolled document =="
else
    echo "== win32-scrollclick (Wine): FAIL — the container swallowed the click =="; exit 1
fi
