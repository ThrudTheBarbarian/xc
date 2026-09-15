#!/bin/sh
# run_json_csv.sh — the `json-csv` gate: UXJSON and UXCSV round-trip text that
# contains their own delimiters.
#
# This exists because UXJSON.serialize used to emit string contents RAW. A value
# holding a quote produced {"say":"he said "hi""} — not JSON, and not readable
# by anything including its own parser. It looked fine in every test that used
# well-behaved text, which is every test anyone writes first.
#
# Pure data structures, so this needs no driver, no window and no display.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v "$xcc" >/dev/null 2>&1 || { echo "== json-csv: no compiler ('$xcc'); set XCC =="; exit 2; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
arch=$(uname -m); case "$arch" in arm64|aarch64) A=arm64 ;; *) A=x86_64 ;; esac

"$xcc" -A "$A" -I "$here" "$here/tests/json_csv_test.xc" -o "$work/json_csv" -q || {
    echo "== json-csv: FAILED to build =="; exit 1; }

# MallocScribble fills freed memory with 0x55, so a buffer the two-pass
# serializer under-measured shows up as garbage rather than as luck.
MallocScribble=1 "$work/json_csv" | tee "$work/out"
grep -q "== json-csv: OK ==" "$work/out" || exit 1

# test_json.xc and test_integration.xc existed but no gate ran them — they are
# not in run_gem_tests.sh's list. Fold them in here so the data classes have one
# place that covers them.
for t in test_json test_integration; do
    "$xcc" -A "$A" -I "$here" "$here/$t.xc" -o "$work/$t" -q || {
        echo "== json-csv: $t FAILED to build =="; exit 1; }
    if MallocScribble=1 "$work/$t" | tail -1 | grep -q "^PASS:"; then
        echo "  ok   $t"
    else
        echo "  FAIL $t"; exit 1
    fi
done
echo "== json-csv: OK (with $(echo test_json test_integration | wc -w | tr -d ' ') legacy suites) =="
