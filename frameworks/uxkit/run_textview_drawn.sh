#!/bin/sh
# run_textview_drawn.sh -- UXTextView drawn and edited by the toolkit, where the backend has no
# editor of its own (GEM's case): run on the web driver under node with no page, which is one.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v node >/dev/null || { echo "== textview-drawn: skipped (no node on PATH) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== textview-drawn: building test_textview_drawn for wasm32 =="
"$xcc" -A wasm32 -I "$here" -o "$work/test_textview_drawn" "$here/test_textview_drawn.xc" -q 2>/dev/null

echo "== textview-drawn: running under node + the recording rig =="
out=$(node --require "$here/ux_web_node.js" "$work/test_textview_drawn.js")
echo "$out"
echo "$out" | grep -q "^PASS" || { echo "== textview-drawn: FAILED =="; exit 1; }
echo "== textview-drawn: OK =="
