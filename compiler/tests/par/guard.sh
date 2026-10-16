#!/bin/bash
# guard.sh — a par block whose write and read differ by a captured offset
# carries a run-time guard (the header's guard= word): an offset that keeps
# the work items apart runs in parallel, one that makes them meet runs
# serially, and both answers are the serial loop's.
#
#   XC=bin/osx/xcc-xc bash tests/par/guard.sh
set -u
export XC_PAR_REMOTE=none     # discovery is on by default; this test names no daemon
XC=${XC:-bin/osx/xcc-xc}
L=$(mktemp -d "${TMPDIR:-/tmp}/par-guard.XXXX")
f=par_guard_offset
rc=0
if ! $XC -q -O2 -H . -o "$L/$f" "tests/fixtures/$f.xc" > "$L/build" 2>&1; then
    echo "FAIL guard: $f does not build"; head -3 "$L/build"; exit 1
fi
mkdir -p "$L/st"
XCC_SETTINGS_DIR="$L/st" XC_PAR_REPORT=1 "$L/$f" > "$L/out" 2>&1
if ! grep -v '^par:' "$L/out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null; then
    echo "FAIL guard: the answers differ"; grep -v '^par:' "$L/out" | head -3; rc=1
fi
# The report line comes before the run's output line: one serial run, and it
# is the second block run's (the meeting offset).
n=$(grep -c 'two work items touch the same element, so it runs serially' "$L/out")
before=$(awk '/^apart:/{exit} /runs serially/{c++} END{print c+0}' "$L/out")
if [ "$n" = 1 ] && [ "$before" = 0 ]; then
    echo "PASS guard"
else
    echo "FAIL guard: $n serial run(s), $before before the apart result"; grep 'shift' "$L/out" | head -4; rc=1
fi
[ $rc = 0 ] && rm -rf "$L"
echo "--- guard: $([ $rc = 0 ] && echo pass || echo FAIL) ---"
exit $rc
