#!/bin/bash
# probe.sh — XC_PAR_PROBE=1: a block's first run is a sweep of tile sizes per
# worker, the written arrays put back between passes, and what it found is
# saved as priors (par.probe, par.learned) the next run starts from. The
# answer must be the plain run's both times.
#
#   XC=bin/osx/xcc-xc bash tests/par/probe.sh
set -u
XC=${XC:-bin/osx/xcc-xc}
L=$(mktemp -d "${TMPDIR:-/tmp}/par-probe.XXXX")
rc=0
f=par_simd_buffers
if ! $XC -q -O2 -H . -o "$L/$f" "tests/fixtures/$f.xc" > "$L/build" 2>&1; then
    echo "FAIL probe: $f does not build"; head -3 "$L/build"; exit 1
fi
mkdir -p "$L/st"
XCC_SETTINGS_DIR="$L/st" XC_PAR_REMOTE=none XC_PAR_PROBE=1 XC_PAR_REPORT=1 "$L/$f" > "$L/probe.out" 2>&1
if grep -v '^par:' "$L/probe.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null \
   && grep -q 'par: probe: .*: knee ' "$L/probe.out" \
   && grep -q "^par\.probe\." "$L"/st/*.conf 2>/dev/null; then
    echo "PASS probe sweep"
else
    echo "FAIL probe sweep"; grep -v '^par:' "$L/probe.out" | diff - "tests/fixtures/$f.expected.out" | head -3; grep 'probe' "$L/probe.out" | head -3; ls "$L/st"; rc=1
fi
XCC_SETTINGS_DIR="$L/st" XC_PAR_REMOTE=none XC_PAR_REPORT=1 "$L/$f" > "$L/after.out" 2>&1
if grep -v '^par:' "$L/after.out" | diff -q - "tests/fixtures/$f.expected.out" > /dev/null && ! grep -q 'par: probe:' "$L/after.out"; then
    echo "PASS probe priors"
else
    echo "FAIL probe priors"; grep 'probe\|chain' "$L/after.out" | head -3; rc=1
fi
[ $rc = 0 ] && rm -rf "$L"
echo "--- probe: $([ $rc = 0 ] && echo pass || echo FAIL) ---"
exit $rc
