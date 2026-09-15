#!/bin/sh
# run_rocks_guides.sh — the `rocks-guides` gate.  See test_rkguides.xc for what it claims.
# Pure model/geometry: no window, no driver, so it runs anywhere xcc does.
set -e
here=$(cd "$(dirname "$0")" && pwd)
ux="$here/../../frameworks/uxkit"
xcc=${XCC:-xcc}
command -v "$xcc" >/dev/null 2>&1 || { echo "== rocks-guides: no compiler ('$xcc'); set XCC =="; exit 2; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
"$xcc" -A arm64 -I "$ux" -I "$here/xc" "$here/xc/test_rkguides.xc" -o "$work/t" -q

out=$("$work/t" 2>&1 | grep -v Warning) || true
echo "$out"
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== rocks-guides: FAILED =="; exit 1; }
echo "== rocks-guides: OK =="
