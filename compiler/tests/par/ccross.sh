#!/bin/bash
# ccross.sh — a C program cross-built from a Mac (2026-10-24): `xcc -A x86_64
# prog.c` gave clang no target, so its half of the split (rest.o) was a host
# object the x86-64 link refused. clang now gets the target's triple and the
# target's C headers (the musl or mingw sysroot); without them the driver says
# so. arm64 Linux too (2026-10-30), its triple from the target table's
# c-triple and its headers glibc's, in a sysroot's usr/include; with
# XTC_LINUX_ARM64_HOST set the program runs there. macOS only (the cross
# case); skipped without clang or the sysroots.
#
#   bash tests/par/ccross.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
[ "$(uname -s)" = Darwin ] || { echo "ccross: macOS only, skipped"; exit 0; }
command -v clang > /dev/null || { echo "ccross: no clang, skipped"; exit 0; }
XC=${XC:-bin/osx/xcc-xc}
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/p.c" <<'C'
#include <stdio.h>
static double xs[4096];
int main(void)
    {
    double s = 0;
    for (int i = 0; i < 4096; i++) xs[i] = i * 0.5;
    for (int i = 0; i < 4096; i++) s += xs[i];
    printf("%.1f\n", s);
    return 0;
    }
C
if [ -f /opt/clang/linux/x86_64-linux-musl/include/stdio.h ]; then
    "$XC" -q -A x86_64 -H . -o "$W/px" "$W/p.c" > "$W/bx" 2>&1 || { echo "FAIL x86_64: does not build"; head -3 "$W/bx"; fail=1; }
    [ -f "$W/px" ] && { file "$W/px" | grep -q 'ELF 64-bit.*x86-64' || { echo "FAIL x86_64: not an x86-64 ELF: $(file -b "$W/px")"; fail=1; }; }
    # No headers: said, not a link failure.
    XTC_MUSL_ROOT="$W/none" "$XC" -q -A x86_64 -H . -o "$W/pn" "$W/p.c" > "$W/bn" 2>&1 && { echo "FAIL: built without headers"; fail=1; }
    grep -q "needs that target's C headers" "$W/bn" || { echo "FAIL: no clear refusal without headers:"; head -2 "$W/bn"; fail=1; }
else
    echo "ccross: no musl sysroot, x86_64 skipped"
fi
if [ -f /opt/clang/win64/x86_64-w64-mingw32/include/stdio.h ]; then
    "$XC" -q -A win64 -H . -o "$W/pw.exe" "$W/p.c" > "$W/bw" 2>&1 || { echo "FAIL win64: does not build"; head -3 "$W/bw"; fail=1; }
    [ -f "$W/pw.exe" ] && { file "$W/pw.exe" | grep -q 'PE32+' || { echo "FAIL win64: not a PE32+: $(file -b "$W/pw.exe")"; fail=1; }; }
    if [ -f "$W/pw.exe" ] && command -v wine > /dev/null; then
        got=$(WINEPREFIX=${WINEPREFIX:-$HOME/.wine-gates} WINEDLLOVERRIDES="winedbg.exe=d" timeout 60 wine "$W/pw.exe" 2>/dev/null | tr -d '\r')
        [ "$got" = "4193280.0" ] || { echo "FAIL win64: gives '$got'"; fail=1; }
    fi
else
    echo "ccross: no mingw sysroot, win64 skipped"
fi
A=${XTC_ARM64_LINUX_ROOT:-/opt/clang/linux/aarch64-linux-gnu}
if [ -f "$A/usr/include/stdio.h" ]; then
    "$XC" -q -A arm64-linux -H . -o "$W/pa" "$W/p.c" > "$W/ba" 2>&1 || { echo "FAIL arm64-linux: does not build"; head -3 "$W/ba"; fail=1; }
    [ -f "$W/pa" ] && { file "$W/pa" | grep -q 'ELF 64-bit.*aarch64' || { echo "FAIL arm64-linux: not an arm64 ELF: $(file -b "$W/pa")"; fail=1; }; }
    XTC_ARM64_LINUX_ROOT="$W/none" "$XC" -q -A arm64-linux -H . -o "$W/pan" "$W/p.c" > "$W/ban" 2>&1 && { echo "FAIL arm64-linux: built without headers"; fail=1; }
    grep -q "XTC_ARM64_LINUX_ROOT" "$W/ban" || { echo "FAIL arm64-linux: the refusal does not name XTC_ARM64_LINUX_ROOT:"; head -2 "$W/ban"; fail=1; }
    H=${XTC_LINUX_ARM64_HOST:-}
    if [ -f "$W/pa" ] && [ -n "$H" ]; then
        scp -o BatchMode=yes -q "$W/pa" "$H:ccross.bin" \
            && got=$(ssh -o BatchMode=yes "$H" './ccross.bin; rm -f ccross.bin') \
            && [ "$got" = "4193280.0" ] || { echo "FAIL arm64-linux: gives '${got:-nothing}' on the host"; fail=1; }
    fi
else
    echo "ccross: no arm64 Linux sysroot, arm64-linux skipped"
fi
[ $fail = 0 ] && echo "ccross: ok"
exit $fail
