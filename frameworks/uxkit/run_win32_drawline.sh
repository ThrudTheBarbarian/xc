#!/bin/sh
# make win32-drawline — UXGdiGraphics.drawLine must draw a UNIFORM stroke, not a wedge that is heavier on
# the right (the old triangle fake made every rectangle look heavy-right).  Renders a frame to an offscreen
# bitmap under Wine and reads the pixels back.  Skips cleanly when wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32-drawline: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-drawline: compiling for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_drawline.exe" "$here/test_win32_drawline.xc" -q 2>/dev/null
echo "== win32-drawline: launching under Wine =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 40 wine test_win32_drawline.exe 2>/dev/null)
printf '%s\n' "$got"
exp=$(cat "$here/expected_win32_drawline.out")
if [ "$got" = "$exp" ]; then echo "== win32-drawline (Wine): PASS — uniform stroke, no right-heavy wedge =="
else echo "== win32-drawline (Wine): FAIL =="; printf 'want:\n%s\n' "$exp"; exit 1; fi
