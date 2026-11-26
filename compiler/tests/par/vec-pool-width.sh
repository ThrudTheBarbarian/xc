#!/bin/bash
# vec-pool-width.sh — a reduction whose body needs more than the 14 vector
# registers of SSE/AVX2 but fits AVX-512's 30 (the C++ md5_mask benchmark:
# MD5's F and G as (b&c)|(~b&d), ~b shared between rounds) vectorises in the
# AVX-512 clone: x86-64 builds have main$avx512. On an x86-64 Linux host with
# AVX-512 the program also gives clang++'s checksum. Skipped where xcc cannot
# build C++ for x86-64 (no clang++, or no Linux C++ headers on macOS).
#
#   bash tests/par/vec-pool-width.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang++ --version >/dev/null 2>&1; then echo "--- vec-pool-width: skipped (no clang++) ---"; exit 0; fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
F=../benchmark/par/cpp/md5_mask.cpp
if ! "$XC" -q -A x86_64 -O3 -std=c++17 --par-style=cpu -H . -o "$W/x" "$F" > "$W/b" 2>&1; then
    if [ "$PLAT" = osx ]; then echo "--- vec-pool-width: skipped (no x86-64 Linux C++ build here) ---"; exit 0; fi
    echo "FAIL vec-pool-width: md5_mask.cpp does not build for x86-64"; grep -v warning "$W/b" | head -3
    echo "--- vec-pool-width: FAIL ---"; exit 1
fi
if ! nm "$W/x" | grep -q 'main\$avx512'; then
    echo "FAIL vec-pool-width: md5_mask.cpp's inner loop is not vectorised for AVX-512 (no main\$avx512)"
    echo "--- vec-pool-width: FAIL ---"; exit 1
fi
if [ "$PLAT" = linux ] && [ "$(uname -m)" = x86_64 ] && grep -q avx512f /proc/cpuinfo; then
    clang++ -O2 -std=c++17 -o "$W/ref" "$F" || { echo "FAIL vec-pool-width: clang++ does not build it"; exit 1; }
    want=$("$W/ref" | cut -d' ' -f1)
    got=$("$W/x" | cut -d' ' -f1)
    if [ "$got" != "$want" ]; then
        echo "FAIL vec-pool-width: checksum $got, clang++'s $want"
        echo "--- vec-pool-width: FAIL ---"; exit 1
    fi
fi
echo "--- vec-pool-width: pass ---"
