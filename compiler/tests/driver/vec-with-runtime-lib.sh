#!/bin/bash
# vec-with-runtime-lib.sh — a loop vectorises the same whether the program
# links libRuntime or carries its runtime (2026-11-03: string_scan's loop,
# an if-converted count beside a sum, stayed scalar against libRuntime, 11 s
# against 0.47, because the blocks if-conversion left were coalesced only in
# a function where a static-init guard was folded, and a library's classes
# have none).
#
# The host's own target: main's vector code must be the same in both builds.
#
#   bash tests/driver/vec-with-runtime-lib.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$([ "$(uname -s)" = Darwin ] && echo osx || echo linux)
XC=${XC:-bin/$PLAT/xcc-xc}
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) ROW=arm64-macos; EXT=dylib; VEC='v[0-9]+\.(16b|8h|4s|2d)' ;;
    Linux-x86_64) ROW=x86_64-linux; EXT=so; VEC='[xy]mm[0-9]+' ;;
    Linux-aarch64) ROW=arm64-linux; EXT=so; VEC='v[0-9]+\.(16b|8h|4s|2d)' ;;
    *) echo "vec-with-runtime-lib: skipped (no libRuntime row for this host)"; exit 0 ;;
esac
[ -f "support/runtime-lib/$ROW/libRuntime.$EXT" ] || { echo "vec-with-runtime-lib: skipped (no libRuntime: make runtime-libs)"; exit 0; }
W=$(mktemp -d /tmp/vec-rl.XXXX)
trap 'rm -rf "$W"' EXIT
fail=0
# The benchmark itself: its timing calls are part of the shape (a smaller
# copy without them vectorised either way).
SRC=../benchmark/src/string_scan.xc
[ -f "$SRC" ] || { echo "vec-with-runtime-lib: skipped (no $SRC)"; exit 0; }
# main's code, all its SIMD copies (main, main$avx2, ...), to the next .globl.
fn_of() { awk '/^_?main(\$[a-z0-9]+)?:$/{p=1;next} /\.globl/{p=0} p' "$1"; }
# The two mains differ only in the Stdio guard (the library's classes have
# none), which has no vector code: the vector instructions must match.
for mode in lib src; do
    flag=""; [ $mode = src ] && flag="--no-runtime-lib"
    "$XC" -q -H . -O3 -fno-bounds-check -I ../benchmark/src $flag -S -o "$W/$mode.s" "$SRC" || { echo "FAIL vec-with-runtime-lib: $mode build"; fail=1; }
done
nl=$(fn_of "$W/lib.s" | grep -cE "$VEC"); ns=$(fn_of "$W/src.s" | grep -cE "$VEC")
[ "$ns" -gt 0 ] || { echo "FAIL vec-with-runtime-lib: the loop is scalar even with its runtime compiled in"; fail=1; }
[ "$nl" = "$ns" ] || { echo "FAIL vec-with-runtime-lib: main has $nl vector instructions with libRuntime, $ns without"; fail=1; }
[ $fail = 0 ] && echo "vec-with-runtime-lib: ok"
exit $fail
