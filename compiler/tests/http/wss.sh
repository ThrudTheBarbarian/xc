#!/bin/bash
# tests/http/wss.sh — a `wss:` WebSocket server and client in one process
# (tests/http/wss_loopback.xc), built with each compiler for the host and
# run against tests/http/wss_loopback.expected.out. Needs the installed TLS
# library (/opt/xcc/3p, or $XCC_3P); the program makes its own certificate.
#
#   bash tests/http/wss.sh
set -u
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT"
export XCC_3P=${XCC_3P:-/opt/xcc/3p}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
rc=0
for C in xcc xcc-xc; do
    [ -x "bin/$XC_PLAT/$C" ] || continue
    mkdir -p "$WORK/$C"
    if ! "bin/$XC_PLAT/$C" -q -O2 -H . -o "$WORK/$C/wss" tests/http/wss_loopback.xc > "$WORK/$C/build" 2>&1; then
        echo "FAIL wss ($C): does not build"; head -3 "$WORK/$C/build"; rc=1; continue
    fi
    if "$WORK/$C/wss" "$WORK/$C" > "$WORK/$C/out" 2>&1 && diff -q "$WORK/$C/out" tests/http/wss_loopback.expected.out > /dev/null; then
        echo "PASS wss ($C)"
    else
        echo "FAIL wss ($C)"; diff "$WORK/$C/out" tests/http/wss_loopback.expected.out | head -5; rc=1
    fi
done
echo "--- wss: $([ $rc = 0 ] && echo pass || echo FAIL) ---"
exit $rc
