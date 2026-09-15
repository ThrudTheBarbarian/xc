#!/bin/bash
# irwide-diff.sh — the ported IR lowering against xcc-fe, over the WHOLE tree.
# =================================================================
#
# self-hosting M6b. `ir-diff.sh` runs the 53 hand-written fixtures in
# tests/ir-lowering; this runs the same comparison over every `.xc` the sema
# harness sweeps — the fixture corpus, every platform's standard library, and
# the self-hosted compiler's own sources.
#
# The 53 fixtures were WRITTEN to pin specific shapes, so passing them says the
# shapes are right. It does not say the lowering is finished: a library file is
# thousands of lines of code nobody chose for its shape, and that is the
# question this asks. The number here is the one that decides whether a
# self-hosted `xcc-fe` can be dropped in.
#
#   bash selfhost/tools/irwide-diff.sh [pattern]
#
# A file the slice does not handle exits 3 and is counted `unsupported`, never
# as a pass. A file the ORACLE cannot compile is counted separately and never
# scored — a harness that treats "neither side produced anything" as agreement
# is worse than no harness.

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc-fe" ] || BIN=bin/linux
WORK=${TMPDIR:-/tmp}/irwide.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

INCS=(-I support/generic/lib -I support/arm64/lib -I support/xt6502/lib
      -I support/arm9/lib -I support/atarist/lib -I support/x86_64/lib
      -I support/win64/lib -I support/win64/selfhost-iface -I support/6502/lib
      -I selfhost/lexer -I selfhost/preproc -I selfhost/parser -I selfhost/sema
      -I selfhost/ir -I selfhost/opt -I selfhost/driver)
# selfhost/asm and selfhost/codegen are deliberately NOT here. Both define
# Arm64.xc, M68k.xc and X86_64.xc, so putting them on one search path makes
# `#import "Arm64.xc"` resolve to whichever directory comes first — the
# assembler where the back end was meant, or the reverse. That is not extra
# coverage, it is a WRONG comparison: tried it, and it manufactured three
# "divergences" that were purely the wrong file being imported.

echo "building xtir (xtc → native arm64)…"
"$BIN/xcc" -O2 -A arm64 -o "$WORK/xtir" selfhost/tools/xtir.xc \
    "${INCS[@]}" 2>&1 | grep -E "^[^ ].*error" && exit 1

PATTERN=${1:-}
pass=0; fail=0; unsup=0; oracle=0
declare -a FAILED
declare -a UNSUP
declare -a ORACLE_FAILED

# SHARD_I/SHARD_N: run only every Nth file, so one harness can be split
# across several parallel slots. all-diff uses it on the long ones; the
# default 0/1 is every file, which is what a direct run gets.
FILES=$(find tests support selfhost -name '*.xc' -not -path 'tests/fuzz/findings/*' | sort | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')
for f in $FILES; do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
    # -m xt EXPLICITLY — the port is run with `-D ARCH_6502=1` below, so the
    # oracle must target the same machine. This used to be the default; xcc now
    # builds for the host unless told otherwise, as cc does.
    if ! "$BIN/xcc-fe" -m xt "$f" -o "$WORK/oracle.ir" "${INCS[@]}" 2>"$WORK/oracle.err" \
       || [ ! -s "$WORK/oracle.ir" ]; then
        # SAY WHICH. A silently-counted skip is indistinguishable from a pass in
        # the summary line, so the port is simply never compared on that file and
        # nobody notices. That blind spot is how a bare `return;` in a bool
        # function sat in Xt6502.xc (#1011) while the sweep reported all-clear.
        # sema-diff has always named them; this one only counted them.
        oracle=$((oracle+1))
        ORACLE_FAILED+=("$f: $(grep -m1 'error:' "$WORK/oracle.err" 2>/dev/null \
                              | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-90)")
        continue
    fi
    "$WORK/xtir" -D ARCH_6502=1 "${INCS[@]}" "$f" > "$WORK/port.ir" 2>/dev/null
    rc=$?
    if [ $rc -eq 3 ]; then
        unsup=$((unsup+1))
        UNSUP+=("$("$WORK/xtir" -D ARCH_6502=1 "${INCS[@]}" "$f" 2>/dev/null | grep unsupported | sed 's/.*unsupported: //')")
        continue
    fi
    if [ $rc -ne 0 ]; then fail=$((fail+1)); FAILED+=("$f (exit $rc)"); continue; fi
    if diff -q "$WORK/oracle.ir" "$WORK/port.ir" >/dev/null; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        FAILED+=("$f ($(diff "$WORK/oracle.ir" "$WORK/port.ir" | grep -c '^[<>]') lines)")
    fi
done

if [ "${#UNSUP[@]}" -gt 0 ]; then
    echo "--- unsupported, by cause:"
    printf '%s\n' "${UNSUP[@]}" | sort | uniq -c | sort -rn | head -25
fi
if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- differing (first 25):"
    printf '  %s\n' "${FAILED[@]}" | head -25
fi
if [ ${#ORACLE_FAILED[@]} -gt 0 ]; then
    echo "--- oracle could not build these (NOT compared, not passes):"
    printf '  %s\n' "${ORACLE_FAILED[@]}"
fi
echo "--- irwide-diff: pass=$pass fail=$fail unsupported=$unsup oracle-failed=$oracle ---"
# A harness that REPORTS failures must also SIGNAL them. These printed the
# summary and fell off the end with status 0, which is fine for a human
# reading the table and useless to CI, to `&&` chains, and to anything else
# that checks status instead of stdout.  FAILS -> non-zero.
[ "$fail" -eq 0 ] || exit 1
