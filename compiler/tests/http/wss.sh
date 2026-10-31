#!/bin/bash
# tests/http/wss.sh — a `wss:` WebSocket server and client in one process
# (tests/http/wss_loopback.xc), built with each compiler for the host and
# run against tests/http/wss_loopback.expected.out. It needs the TLS library:
# $XCC_3P when given, else the host's built here by the compiler under test
# (frameworks/3p/tls/install.sh), so the test never depends on what is
# installed. Each compiler install has its own 3p (owner 2026-10-31: a
# library built by an earlier xcc has the old object layout and is refused).
# The program makes its own certificate.
#
#   [XCC_3P=<3p root>] bash tests/http/wss.sh
set -u
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK:?}"' EXIT
rc=0
if [ -z "${XCC_3P:-}" ]; then
    HOSTPLAT=$( [ "$(uname -s)" = Darwin ] && echo arm64 || echo x86_64 )
    if ! (cd ../frameworks/3p/tls && XCC="$ROOT/bin/$XC_PLAT/xcc-xc" XCC_HOME="$ROOT" DEST="$WORK/3p/tls" \
              TLS_PLATFORMS=$HOSTPLAT sh install.sh) > "$WORK/tls-build" 2>&1 \
       || [ ! -e "$WORK/3p/tls/$HOSTPLAT" ]; then
        echo "FAIL wss: the TLS library does not build: $(tail -3 "$WORK/tls-build")"
        echo "--- wss: FAIL ---"; exit 1
    fi
    export XCC_3P="$WORK/3p"
fi
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
