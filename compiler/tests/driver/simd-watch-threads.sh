#!/bin/bash
# simd-watch-threads.sh — many CPU lanes write a watched block at once
# (2026-10-26). The first fault made the pages writable; every later one,
# already in flight, was taken for a real access violation (SIGBUS, SIGSEGV,
# 0xC0000005). fixtures/simd_watch_threads.xc watches a 4 MB block and has a
# par block on the CPU lanes write it, 200 times; it must finish with its sum.
# On the Windows host too, with XTC_WIN64_HOST.
#
#   [XTC_WIN64_HOST=<host>] bash tests/driver/simd-watch-threads.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
F=tests/fixtures/simd_watch_threads.xc
WANT=$(cat tests/fixtures/simd_watch_threads.expected.out)
"$XC" -q -O2 -H . -o "$W/p" "$F" || { echo "FAIL simd-watch-threads: does not build"; exit 1; }
got=$(XC_PAR=cpu "$W/p" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$got" = "$WANT" ] || { echo "FAIL simd-watch-threads: rc $rc, '$got'"; fail=1; }
WH=${XTC_WIN64_HOST:-}
if [ -n "$WH" ]; then
    SSHO="-o BatchMode=yes -o LogLevel=ERROR"
    "$XC" -q -A win64 -O2 -H . -o "$W/p.exe" "$F" || { echo "FAIL simd-watch-threads: win64 build"; exit 1; }
    scp $SSHO -q "$W/p.exe" "$WH:swt.exe" || { echo "FAIL simd-watch-threads: copy"; exit 1; }
    got=$(ssh $SSHO "$WH" '$env:XC_PAR="cpu"; .\swt.exe; "rc=$LASTEXITCODE"; Remove-Item swt.exe' | tr -d '\r' | tr '\n' ' ')
    [ "$got" = "$WANT rc=0 " ] || { echo "FAIL simd-watch-threads: win64 gives '$got'"; fail=1; }
fi
[ $fail = 0 ] && echo "simd-watch-threads: ok"
exit $fail
