#!/bin/sh
# make win32-rules — the kitchen sink's rule editor over UXPredicate, driven headlessly.
# Builds the real KSRulesBoard (the same code the three backends show), sets rule rows, and checks the
# filtered row set: AND/OR/NOT, the string and numeric operators, MATCHES, inactive (empty) rows, and
# the row add/delete shuffle.  Win32/Wine because that backend runs a whole UI headlessly; nothing in
# the test is Win32-specific.  Skips when wine is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
if ! command -v wine >/dev/null 2>&1; then echo "== win32-rules: skipped (wine absent) =="; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== win32-rules: compiling for win64 =="
"$xcc" -A win64 -I "$here" -o "$work/test_win32_rules.exe" "$here/test_win32_rules.xc" -q 2>/dev/null
echo "== win32-rules: launching under Wine =="
got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" timeout 60 wine test_win32_rules.exe 2>/dev/null)
printf '%s\n' "$got"
if printf '%s\n' "$got" | grep -q '^PASS: rule rows -> predicate tree -> filtered rows$'; then
    echo "== win32-rules (Wine): PASS — the rule editor drives the engine =="
else
    echo "== win32-rules (Wine): FAIL =="; exit 1
fi
