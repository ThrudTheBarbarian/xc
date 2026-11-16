#!/bin/bash
# layout-warnings.sh — the memory map -dl draws says what it passed over
# (#298): an unknown section, an unknown key, and a value not of its key's
# form each give a warning with file:line on stderr, where they were dropped
# without a word. Every layout in the tree draws with none.
#
#   bash tests/driver/layout-warnings.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cp support/xt6502/layouts/xt.lnk "$W/"
printf '#include "xt.lnk"\n[memroy]\nmain = $2000-$3FFF\n[heap]\ntopp = $9000\ntop = lots\n' > "$W/bad.lnk"
"$XC" -A xt6502 -m "$W/bad.lnk" -dl > "$W/out" 2> "$W/err" || { echo "FAIL layout-warnings: -dl failed: $(head -c 300 "$W/err")"; fail=1; }
grep -q "bad.lnk:2: unknown section \[memroy\]" "$W/err" || { echo "FAIL layout-warnings: no warning for the unknown section"; fail=1; }
grep -q "bad.lnk:5: unknown key 'topp' in \[heap\]" "$W/err" || { echo "FAIL layout-warnings: no warning for the unknown key"; fail=1; }
grep -q "bad.lnk:6: 'top = lots' in \[heap\]: not a value" "$W/err" || { echo "FAIL layout-warnings: no warning for the malformed value"; fail=1; }
grep -q "warning" "$W/out" && { echo "FAIL layout-warnings: a warning went into the map on stdout"; fail=1; }
for l in support/*/layouts/*.lnk support/*/internal/*.lnk tests/xcc-as/cloak1.lnk tests/xcc-as/regc.lnk tests/xcc-as/split.lnk; do
    [ -f "$l" ] || continue
    w=$("$XC" -A xt6502 -m "$l" -dl 2>&1 > /dev/null | grep warning)
    [ -z "$w" ] || { echo "FAIL layout-warnings: $l draws with warnings: $w"; fail=1; }
done
[ $fail = 0 ] && echo "layout-warnings: ok"
exit $fail
