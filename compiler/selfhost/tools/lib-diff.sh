#!/bin/bash
# lib-diff.sh — the two DRIVERS' LIBRARY builds (--emit-lib), byte for byte.
#
#   bash selfhost/tools/lib-diff.sh [pattern]
#
# bin-diff compares executables. A library build takes other paths through
# both compilers: every instance method is a vtable root, slots are numbered
# per class, and the module interface is embedded in the binary
# (`__XTC,__iface`, `.xtc.iface`, the wasm custom section). The ld*-diffs hand
# the ORACLE's interface to both linkers, so none of them sees the interface
# the port writes. Bugs 252 (the interface text and one published slot) and
# 253 (one dispatch slot) lived there with every other harness green.
#
# The library sources under tests/ that are built with --emit-lib, plus one
# fixture in sixteen (a library build of a program is still a library build),
# on every target both drivers link a library for in-house.
#
# An ORACLE failure (the reference cannot build it) is counted and NOT a pass.
# A port REFUSAL is a gap, named separately from a divergence.
set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx; [ -x "$BIN/xcc" ] || BIN=bin/linux
PATTERN=${1:-}
WORK=${TMPDIR:-/tmp}/libdiff.$$
mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT

SELF=(-I selfhost/lexer -I selfhost/preproc -I selfhost/parser -I selfhost/sema
      -I selfhost/ir -I selfhost/opt -I selfhost/codegen -I selfhost/asm
      -I selfhost/link -I selfhost/driver)
echo "building xcc.xc (the xtc driver → native arm64)…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xccxc" selfhost/tools/xcc.xc \
    "${SELF[@]}" > "$WORK/build.log" 2>&1
if [ ! -x "$WORK/xccxc" ]; then grep -a error "$WORK/build.log" | head -5; exit 1; fi

LIBS="tests/arm64/emit-lib/TheLib.xc tests/arm64/emit-lib-overload/OvLib.xc
      tests/x86_64/emit-lib/TheLib.xc
      tests/wasm32/emit-lib/TheLib.xc tests/wasm-shared/SLib.xc
      tests/crossmod/bmlib.xc tests/crossmod/blib.xc tests/crossmod/clib.xc
      tests/crossmod/dclib.xc tests/interop/optional-proto-import/optlib.xc
      tests/selfhost-iface/mod-shape.xc tests/fixtures/class_final.xc
      tests/fixtures/foundation_comparable.xc
      tests/fixtures/overload_virtual_dispatch.xc"
SAMPLE=$(ls tests/fixtures/*.xc | sort | awk 'NR % 16 == 0')
FILES=$(printf '%s\n' $LIBS $SAMPLE | awk '!seen[$0]++' \
    | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')

TARGETS=${LIB_DIFF_TARGETS:-"arm64 android x86_64 arm9 wasm32"}
# arm9 resolves `#import <c>` against the device libc.so; both sides get it.
. "$(dirname "$0")/arm9-sysroot.sh"
[ -z "$ARM9_SYSROOT" ] && echo "!!! no arm9 sysroot: every arm9 row will be oracle-failed"
pass=0; fail=0; unsup=0; oracle=0
declare -a FAILED UNSUP ORACLE
for arch in $TARGETS; do
    for f in $FILES; do
        [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
        [ -f "$f" ] || continue
        b=$(basename "$f" .xc)
        EXTRA=()
        [ "$arch" = arm9 ] && [ -n "$ARM9_SYSROOT" ] && EXTRA=(-L "$ARM9_SYSROOT")
        rm -rf "$WORK/r" "$WORK/x"; mkdir -p "$WORK/r" "$WORK/x"
        # Each in its own directory under the same name: the output's file
        # name is recorded in the library (its install name, its soname).
        if ! "$BIN/xcc" -A "$arch" -H . -q --emit-lib ${EXTRA[@]+"${EXTRA[@]}"} -o "$WORK/r/lib$b" "$f" \
                 >/dev/null 2>&1 || [ -z "$(ls "$WORK/r")" ]; then
            oracle=$((oracle+1)); ORACLE+=("$arch/$b"); continue
        fi
        "$WORK/xccxc" -A "$arch" -H . -q --emit-lib ${EXTRA[@]+"${EXTRA[@]}"} -o "$WORK/x/lib$b" "$f" \
            >"$WORK/port.log" 2>&1
        if [ -z "$(ls "$WORK/x")" ]; then
            why=$(grep -o 'error: .*' "$WORK/port.log" | head -1)
            unsup=$((unsup+1)); UNSUP+=("$arch/$b — ${why:-produced no output}")
            continue
        fi
        # A wasm32 library is a module plus its loader; compare every file.
        same=1
        for o in "$WORK"/r/*; do
            cmp -s "$o" "$WORK/x/$(basename "$o")" || same=0
        done
        [ "$(ls "$WORK/r" | wc -l)" = "$(ls "$WORK/x" | wc -l)" ] || same=0
        if [ "$same" = 1 ]; then
            pass=$((pass+1))
        else
            fail=$((fail+1))
            FAILED+=("$arch/$b: $(cd "$WORK/r" && for o in *; do printf '%s %s vs %s  ' "$o" "$(wc -c < "$o" | tr -d ' ')" "$(wc -c < "../x/$o" 2>/dev/null | tr -d ' ')"; done)")
        fi
    done
done

echo "--- lib-diff: pass=$pass fail=$fail unsupported=$unsup oracle-failed=$oracle ---"
if [ "$fail" -gt 0 ]; then
    echo "--- differing (first 15):"; printf '  %s\n' "${FAILED[@]}" | head -15
fi
if [ "$unsup" -gt 0 ]; then
    echo "--- the port REFUSED (a gap, not a divergence):"; printf '  %s\n' "${UNSUP[@]}" | head -10
fi
# A skip is not a pass: name them.
if [ "$oracle" -gt 0 ]; then
    echo "--- not compared (the reference cannot build it):"; printf '  %s\n' "${ORACLE[@]}" | head -30
fi
# NOTHING COMPARED is not a pass (private:docs/bugs/239).
if [ "$pass" -eq 0 ]; then
    echo "--- $(basename "$0"): NOTHING WAS COMPARED — this is not a pass"
    exit 1
fi
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
