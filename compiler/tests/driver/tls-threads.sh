#!/bin/bash
# tls-threads.sh — the vendored Mbed TLS is built with threading (2026-10-24):
# PSA's random generator and key slots are shared by every TLS connection, and
# without MBEDTLS_THREADING_C an xcd serving two programs at once failed both
# handshakes now and then (7 runs in 100 on a loaded 32-thread host; none in
# 100 with threading). Linux, Android and iOS (pthreads; win64 is still
# without). The libraries are prebuilt, so the check is that the
# crypto core uses pthread mutexes; the race itself is remote.sh's
# "two programs".
#
#   bash tests/driver/tls-threads.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
NM=$(command -v llvm-nm || command -v nm)
fail=0; seen=0
for t in linux android ios; do
    D=../frameworks/3p/tls/mbedtls-$t
    [ -f "$D/libtfpsacrypto.a" ] || continue
    seen=$((seen+1))
    n=$("$NM" "$D/libtfpsacrypto.a" 2>/dev/null | grep -c 'pthread_mutex_lock')
    [ "${n:-0}" -gt 0 ] || { echo "FAIL tls-threads: $D/libtfpsacrypto.a is built without threading"; fail=1; }
done
[ $seen -gt 0 ] || { echo "tls-threads: no vendored Mbed TLS, skipped"; exit 0; }
[ $fail = 0 ] && echo "tls-threads: ok"
exit $fail
