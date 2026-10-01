#!/bin/sh
# run_web_round.sh -- a rounded panel (setCornerRadius + setBorderRGB) on the web backend, replayed by
# the node rig: the corner cut, the edge, the content inside, the bar inset.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v node >/dev/null || { echo "== web-round: skipped (no node on PATH) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== web-round: building test_web_round for wasm32 =="
"$xcc" -A wasm32 -I "$here" -o "$work/test_web_round" "$here/test_web_round.xc" -q 2>/dev/null

echo "== web-round: running under node + the recording rig =="
out=$(node --require "$here/ux_web_node.js" "$work/test_web_round.js")
echo "$out"
echo "$out" | grep -q "^PASS" || { echo "== web-round: FAILED =="; exit 1; }
echo "== web-round: OK =="
