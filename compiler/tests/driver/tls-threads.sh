#!/bin/bash
# tls-threads.sh — the vendored Mbed TLS is built with threading (2026-10-24):
# PSA's random generator and key slots are shared by every TLS connection, and
# without MBEDTLS_THREADING_C an xcd serving two programs at once failed both
# handshakes now and then (7 runs in 100 on a loaded 32-thread host; none in
# 100 with threading). The libraries are prebuilt, so the check is that the
# crypto core uses pthread mutexes; the race itself is remote.sh's
# "two programs".
#
#   bash tests/driver/tls-threads.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
D=../frameworks/3p/tls/mbedtls-linux
[ -f "$D/libtfpsacrypto.a" ] || { echo "tls-threads: no vendored Linux Mbed TLS, skipped"; exit 0; }
NM=$(command -v llvm-nm || command -v nm)
n=$("$NM" "$D/libtfpsacrypto.a" 2>/dev/null | grep -c 'pthread_mutex_lock')
[ "${n:-0}" -gt 0 ] || { echo "FAIL tls-threads: $D/libtfpsacrypto.a is built without threading"; exit 1; }
echo "tls-threads: ok"
