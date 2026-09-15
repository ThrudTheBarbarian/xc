#!/bin/sh
# make designable — bug 026 activated against the real framework: decorations
# in, compiler-synthesised bodies + factory + load-time registration out,
# under the UXKit spellings.  Host arm64; pure, no window.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
"$xcc" -A arm64 -I "$here" -I "$here/hostgem" "$here/test_designable.xc" -o "$work/td" -q 2>/dev/null
out=$("$work/td" 2>&1)
echo "$out"
echo "$out" | grep -q "^PASS" || { echo "== designable: FAILED =="; exit 1; }
echo "== designable: OK =="
