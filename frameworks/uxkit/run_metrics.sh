#!/bin/sh
# make metrics — the UXMetrics standards table, both realms, pure host run.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
"$xcc" -A arm64 -I "$here" "$here/test_metrics.xc" -o "$work/metrics" -q 2>/dev/null
out=$("$work/metrics" 2>&1)
echo "$out"
echo "$out" | grep -q "^PASS" || { echo "== metrics: FAILED =="; exit 1; }
echo "== metrics: OK =="
