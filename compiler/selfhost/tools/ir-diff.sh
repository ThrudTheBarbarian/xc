#!/bin/bash
# ir-diff.sh — the ported IR lowering against xcc-fe's own output.
# =================================================================
#
# self-hosting M6b. Unlike the lexer / preprocessor / parser / sema harnesses
# there is no --dump mode to add: the IR text `xcc-fe` writes with -o IS the
# oracle. So this compares `xtir <file>` against `xcc-fe <file> -o -`,
# byte for byte.
#
# The port lowers a SLICE of the language (see selfhost/ir/Lower.xc). A file it
# does not yet handle exits 3 and is counted as `unsupported`, NOT as a pass —
# a harness that scores untested files as agreement is worse than no harness.
#
#   bash selfhost/tools/ir-diff.sh [pattern]
#
# With no pattern, every tests/ir-lowering/*.xc fixture is run: they are small,
# self-contained, and each already has an expected .ir beside it.

set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
BIN=bin/osx
[ -x "$BIN/xcc-fe" ] || BIN=bin/linux
WORK=${TMPDIR:-/tmp}/ir-diff.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

INCS=(-I support/generic/lib -I support/arm64/lib)

echo "building xtir (xtc → native arm64)…"
"$BIN/xcc" -O2 -A arm64 -o "$WORK/xtir" selfhost/tools/xtir.xc \
    "${INCS[@]}" -I selfhost/lexer -I selfhost/preproc -I selfhost/parser \
    -I selfhost/sema -I selfhost/ir -I selfhost/driver 2>&1 | grep -E "error" && exit 1

PATTERN=${1:-}
pass=0; fail=0; unsup=0; oracle=0
declare -a FAILED

for f in tests/ir-lowering/*.xc; do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
    # -m xt EXPLICITLY: the port below is told `-D ARCH_6502=1`, so the
    # oracle must be given the same target. It used to be implicit, back when
    # no -A meant 6502; xcc now defaults to the host, as cc does.
    "$BIN/xcc-fe" -m xt "$f" -o "$WORK/oracle.ir" >/dev/null 2>&1
    if [ ! -s "$WORK/oracle.ir" ]; then oracle=$((oracle+1)); continue; fi
    # The -I list mirrors the oracle's implicit search paths — without it the
    # oracle preludes (Platform.xc is on ITS paths) and the port cannot even
    # resolve the prelude, so every file diverges by the whole ambient
    # surface (task #36).
    "$WORK/xtir" -D ARCH_6502=1 -I support/xt6502/lib -I support/generic/lib "$f" > "$WORK/port.ir" 2>/dev/null
    rc=$?
    if [ $rc -eq 3 ]; then unsup=$((unsup+1)); continue; fi
    if [ $rc -ne 0 ]; then fail=$((fail+1)); FAILED+=("$f (exit $rc)"); continue; fi
    if diff -q "$WORK/oracle.ir" "$WORK/port.ir" >/dev/null; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        FAILED+=("$f ($(diff "$WORK/oracle.ir" "$WORK/port.ir" | grep -c '^[<>]') lines)")
    fi
done

if [ ${#FAILED[@]} -gt 0 ]; then
    echo "--- differing:"
    printf '  %s\n' "${FAILED[@]}"
fi
echo "--- ir-diff: pass=$pass fail=$fail unsupported=$unsup oracle-failed=$oracle ---"
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

[ $fail -eq 0 ]
