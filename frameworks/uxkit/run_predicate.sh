#!/bin/sh
# run_predicate.sh — the `predicate` gate: UXPredicate itself.
#
# The engine had a test (test_predicate.xc) and no gate, so it never ran in a
# sweep.  That was worth fixing on its own, and it also mattered while
# diagnosing win32-rules: the board test was failing three checks, and the first
# question was whether the ENGINE or the TEST was wrong.  Being able to run the
# engine's own coverage answered it in one line — the engine was sound, and the
# board test's values were miswritten.
#
# Pure logic, no driver and no window, so it builds and runs anywhere xcc does.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v "$xcc" >/dev/null 2>&1 || { echo "== predicate: no compiler ('$xcc'); set XCC =="; exit 2; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
"$xcc" -A arm64 -I "$here" "$here/test_predicate.xc" -o "$work/t" -q

out=$("$work/t" 2>&1 | grep -v Warning) || true
echo "$out"
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== predicate: FAILED =="; exit 1; }
echo "== predicate: OK =="
