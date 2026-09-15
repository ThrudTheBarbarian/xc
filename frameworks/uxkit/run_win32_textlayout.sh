#!/bin/sh
# make win32-textlayout — line breaking against REAL glyph metrics under Wine.
# test_textlayout covers the arithmetic wrap; this covers wrapFont, which measures through
# UXViewDriver.textWidth.  Asserts the invariant (no line exceeds the measure), that a narrower
# measure or a bigger font never produces fewer lines, and that a proportional font breaks the text
# differently from the uniform-width estimate — i.e. the metrics are actually consulted.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32-textlayout: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-textlayout: compiling for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_textlayout.exe" "$here/test_win32_textlayout.xc" -q 2>/dev/null
echo "== win32-textlayout: launching under Wine =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 60 wine test_win32_textlayout.exe 2>/dev/null)
printf '%s\n' "$got"
if printf '%s\n' "$got" | grep -q '^PASS: wrapFont breaks on real glyph metrics$'; then
    echo "== win32-textlayout (Wine): PASS — the wrap measures the font it draws =="
else
    echo "== win32-textlayout (Wine): FAIL =="; exit 1
fi
