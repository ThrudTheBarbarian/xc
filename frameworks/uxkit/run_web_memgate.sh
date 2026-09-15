#!/bin/sh
# run_web_memgate.sh — the §10 memory gate on the web backend (`web-memgate`).
# The same open/close-N-forms loop as the GEM/Win32 gates, under Node with the
# recording rig; both counters (the driver's native objects, the allocator's
# address oracle) must return to baseline on the close AND dealloc paths.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v node >/dev/null || { echo "== web-memgate: skipped (no node on PATH) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== web-memgate: building test_web_memgate for wasm32 =="
"$xcc" -A wasm32 -I "$here" -o "$work/test_web_memgate" "$here/test_web_memgate.xc" -q 2>/dev/null

echo "== web-memgate: running under node + the recording rig =="
out=$(node --require "$here/ux_web_node.js" "$work/test_web_memgate.js")
echo "$out"
echo "$out" | grep -q "^PASS" || { echo "== web-memgate: FAILED =="; exit 1; }
echo "== web-memgate: OK — no native or heap leak on either teardown path =="
