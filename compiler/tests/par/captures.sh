#!/bin/bash
# captures.sh — a captured variable is the same value in every CPU chunk
# (2026-10-23). copyChunk(), which makes each chunk after the first, built it
# in a local `t`, so a capture called t was the chunk itself: a pointer failed
# to build and a scalar was silently wrong after the first 512 items. auto may
# put a block on the GPU, which never copies chunks, so this forces the CPU.
#
#   bash tests/par/captures.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
F=tests/fixtures/par_capture_t
"$XC" -q -O2 -H . -o "$W/p" "$F.xc" > "$W/p.b" 2>&1 || { echo "FAIL captures: does not build"; head -3 "$W/p.b"; exit 1; }
if XC_PAR=cpu XC_PAR_THREADS=4 "$W/p" 2>&1 | diff -q - "$F.expected.out" > /dev/null; then
    echo "par captures: ok"
else
    echo "FAIL captures: XC_PAR=cpu gives"; XC_PAR=cpu XC_PAR_THREADS=4 "$W/p" 2>&1 | head -3; exit 1
fi
