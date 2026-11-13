#!/bin/bash
# signed-wrap.sh — integer arithmetic that wraps, on the GPU (#182). A Metal
# kernel did a signed 32-bit + - * << and negation in MSL's `int`, where
# overflow is undefined, and Metal's compiler folded `v + INT_MAX < v` to
# false: a C loop that wraps through `unsigned` gave the CPU's answer on the
# CPU and another under XC_PAR=gpu. Now those operations are done in the
# unsigned type and converted back (`int(uint(a) + uint(b))`), and the GPU
# gives clang's output. macOS only (CUDA's PTX and Vulkan's SPIR-V wrap by
# definition). Skipped without clang.
#
#   bash tests/par/signed-wrap.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
if [ "$(uname -s)" != Darwin ]; then
    echo "--- signed-wrap: skipped (Metal only) ---"
    exit 0
fi
XC=${XC:-bin/osx/xcc-xc}
if ! clang --version > /dev/null 2>&1; then
    echo "--- signed-wrap: skipped (no clang) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
cat > "$W/wrap.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#define N (1 << 20)
int main(void)
    {
    int* a = malloc(N * sizeof(int));
    int* out = malloc(N * sizeof(int));
    for (int i = 0; i < N; i++) a[i] = i - N / 2;
    for (int i = 0; i < N; i++)
        {
        unsigned s = (unsigned)a[i] + 2147483647u;
        int v = a[i];
        int w = (int)s;
        out[i] = (w < v) + 2 * ((int)((unsigned)v * 65599u) < 0) + 4 * ((int)(0u - (unsigned)v) > 0);
        }
    long t = 0;
    for (int i = 0; i < N; i++) t += out[i] * (long)(i % 7 + 1);
    printf("%ld\n", t);
    return 0;
    }
C
clang -O2 -w -o "$W/ref" "$W/wrap.c" || { echo "FAIL signed-wrap: clang does not build the program"; exit 1; }
want=$("$W/ref")
"$XC" -q -O2 -o "$W/wrap" "$W/wrap.c" > "$W/b" 2>&1 \
    || { echo "FAIL signed-wrap: does not build (exit $?)"; tail -3 "$W/b"; exit 1; }
# The kernel's signed add is done in uint.
strings "$W/wrap" | grep -q 'int(uint(v[0-9]*) + uint(' \
    || { echo "FAIL signed-wrap: the Metal kernel adds in signed int"; strings "$W/wrap" | grep -m3 '2147483647L'; fail=1; }
for m in cpu gpu; do
    got=$(XC_PAR=$m "$W/wrap")
    [ "$got" = "$want" ] || { echo "FAIL signed-wrap: XC_PAR=$m gives $got, clang $want"; fail=1; }
done
[ $fail = 0 ] && echo "--- signed-wrap: passed ---"
exit $fail
