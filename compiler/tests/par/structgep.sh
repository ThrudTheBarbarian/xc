#!/bin/bash
# structgep.sh — the reader takes `getelementptr %struct.S, ptr p, i64 %i,
# i32 k` (a field of element [i]) as p[i].k, not p[0].k: tests/par/c-ll/
# struct-gep.ll sums x + y over an array of structs written and read in that
# form, and gives clang's 1019901 with --par-style=cpu and auto, on the CPU
# and GPU. Skipped where there is no clang.
#
#   bash tests/par/structgep.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang --version >/dev/null 2>&1; then
    echo "--- structgep: skipped (no clang) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
LL=$PWD/tests/par/c-ll/struct-gep.ll
fail=0
echo 'int main(void) { return 0; }' > "$W/stub.c"
for ps in cpu auto; do
    XC_C_LL="$LL" "$XC" -q -O3 --par-style=$ps -H . -o "$W/t.$ps" "$W/stub.c" > "$W/b.$ps" 2>&1 \
        || { echo "FAIL structgep: does not build (--par-style=$ps)"; head -3 "$W/b.$ps"; fail=1; continue; }
    for d in cpu gpu; do
        got=$(XC_PAR=$d "$W/t.$ps")
        [ "$got" = "1019901" ] || { echo "FAIL structgep: --par-style=$ps on $d gives $got, clang's 1019901"; fail=1; }
    done
done
[ $fail = 0 ] && echo "--- structgep: pass ---" || echo "--- structgep: FAIL ---"
exit $fail
