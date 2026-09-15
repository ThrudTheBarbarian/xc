#!/bin/sh
# make win32-drawfont — UXGdiGraphics.drawTextFont must honour family + bold/italic (the styled font-chooser
# preview).  Renders "Agjy Agjy" to an offscreen bitmap under Wine and reads the ink back: bold must ink
# heavier than regular at the same family+size, and a monospace family must differ in width from a
# proportional one.  Gates on those invariants, not exact pixel counts.  Skips cleanly when wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32-drawfont: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-drawfont: compiling for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_drawfont.exe" "$here/test_win32_drawfont.xc" -q 2>/dev/null
echo "== win32-drawfont: launching under Wine =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_drawfont.exe 2>/dev/null)
printf '%s\n' "$got"
if printf '%s\n' "$got" | grep -q '^boldHeavier=1 familyDiffers=1$'; then
    echo "== win32-drawfont (Wine): PASS — family + bold/italic take effect =="
else
    echo "== win32-drawfont (Wine): FAIL — style did not take effect =="; exit 1
fi
