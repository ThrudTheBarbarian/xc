#!/bin/bash
# irrt-diff.sh — the IR text, read back and printed again.
# =================================================================
#
# self-hosting M8. `Ir.xc` prints the IR and `IrParse.xc` reads it; between
# them they are the front-end / back-end process boundary, and a self-hosted
# `xtcg-<arch>` cannot exist until the reading half does.
#
# The oracle costs nothing: the text a module prints IS the text the parser
# must accept, so `print(parse(text))` has to reproduce `text` byte for byte.
# No new dump mode, no fixtures — every `.xc` in the tree that the front end
# can compile is a case, at whatever target is asked for.
#
#   bash selfhost/tools/irrt-diff.sh [target] [pattern]
#
# A file the parser does not handle exits 3 and says what stopped it; it is
# counted `unsupported` and never as a pass.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc-fe" ] || BIN=bin/linux
TARGET=${1:-arm64}
PATTERN=${2:-}
WORK=${TMPDIR:-/tmp}/irrt.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "building xtirp (xtc → native arm64)…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xtirp" selfhost/tools/xtirp.xc \
    -I selfhost/ir 2>&1 | grep -E "^[^ ].*error" && exit 1

# arm9 resolves `#import <c>` against the device libc.so, so without the
# loader's build dir on the library path the ORACLE cannot compile most of the
# tree and the sweep silently shrinks to what needs no libc.
# ...and ONLY arm9: pointing another target at the device libc makes its
# oracle import a library that target has no business linking, which scores
# files that cannot really be built.
ARM9_SYSROOT=${XTC_ARM9_SYSROOT:-}
# (bash 3.2 on macOS treats "${LIBARGS[@]}" as unbound when the array is
# EMPTY under `set -u`, hence the +expansion at the use site.)
LIBARGS=()
[ "$TARGET" = arm9 ] && [ -d "$ARM9_SYSROOT" ] && LIBARGS=(-L "$ARM9_SYSROOT")

RUN_INCS=(-I selfhost/lexer -I selfhost/preproc -I selfhost/parser
          -I selfhost/sema -I selfhost/ir)

pass=0; fail=0; unsup=0; oracle=0
declare -a FAILED

# SHARD_I/SHARD_N: run only every Nth file, so one harness can be split
# across several parallel slots. all-diff uses it on the long ones; the
# default 0/1 is every file, which is what a direct run gets.
FILES=$(find tests support selfhost -name '*.xc' -not -path 'tests/fuzz/findings/*' | sort | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')
for f in $FILES; do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
    if ! "$BIN/xcc-fe" -m "$TARGET" -H . "${RUN_INCS[@]}" ${LIBARGS[@]+"${LIBARGS[@]}"} "$f" -o "$WORK/a.ir" \
         >/dev/null 2>&1 || [ ! -s "$WORK/a.ir" ]; then
        oracle=$((oracle+1)); continue
    fi
    "$WORK/xtirp" "$WORK/a.ir" -o "$WORK/b.ir" >/dev/null 2>&1
    rc=$?
    if [ $rc -eq 3 ]; then
        unsup=$((unsup+1))
        FAILED+=("$f — $("$WORK/xtirp" "$WORK/a.ir" 2>&1 | sed 's/.*unsupported: //' | head -1)")
        continue
    fi
    if [ $rc -ne 0 ]; then fail=$((fail+1)); FAILED+=("$f (exit $rc)"); continue; fi
    if diff -q "$WORK/a.ir" "$WORK/b.ir" >/dev/null; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        FAILED+=("$f ($(diff "$WORK/a.ir" "$WORK/b.ir" | grep -c '^[<>]') lines)")
    fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- differing (first 25):"
    printf '  %s\n' "${FAILED[@]}" | head -25
fi
# A target the driver does not know compiles NOTHING, and a harness that
# reports 0/0 for that reads exactly like a clean sweep. Say which it was.
if [ "$pass" -eq 0 ] && [ "$oracle" -gt 0 ]; then
    echo "!!! the oracle compiled NOTHING for -m $TARGET — is that a target name it knows?"
fi
echo "--- irrt-diff[$TARGET]: pass=$pass fail=$fail unsupported=$unsup oracle-failed=$oracle ---"
# A harness that REPORTS failures must also SIGNAL them. These printed the
# summary and fell off the end with status 0, which is fine for a human
# reading the table and useless to CI, to `&&` chains, and to anything else
# that checks status instead of stdout.  FAILS -> non-zero.
[ "$fail" -eq 0 ] || exit 1
# NOTHING COMPARED is not a pass. Every one of these harnesses counts an oracle
# failure — a file the REFERENCE could not build — and skips it, so a broken
# oracle turns the whole sweep into skips and the summary reads pass=0 fail=0.
# Only `fail` was ever checked, so that exited 0 and showed as a clean row in
# all-diff's table. It has now happened twice on ldx86-diff alone, the second
# time hiding 961 uncompared files. private:docs/bugs/239.
if [ "$pass" -eq 0 ]; then
    echo "--- $(basename "$0"): NOTHING WAS COMPARED — this is not a pass"
    exit 1
fi

