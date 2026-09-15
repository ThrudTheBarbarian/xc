#!/bin/sh
# make win32-drawtext — UXGdiGraphics.drawText must honour its `size` argument (the font-chooser preview
# scales on Win32).  Renders "Agjy" at sizes 0/12/40 to an offscreen bitmap under Wine and reads the inked
# height back: the 40px render must ink clearly taller than the 12px one.  Gates on the scales invariant,
# not exact pixel counts (those drift with the Wine font set).  Skips cleanly when wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32-drawtext: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-drawtext: compiling for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_drawtext.exe" "$here/test_win32_drawtext.xc" -q 2>/dev/null
echo "== win32-drawtext: launching under Wine =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_drawtext.exe 2>/dev/null)
printf '%s\n' "$got"
if printf '%s\n' "$got" | grep -q '^scales=1$'; then
    echo "== win32-drawtext (Wine): PASS — drawText scales with size =="
else
    echo "== win32-drawtext (Wine): FAIL — preview did not scale =="; exit 1
fi
