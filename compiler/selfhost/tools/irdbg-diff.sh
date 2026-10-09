#!/bin/bash
# irdbg-diff.sh — `-g` IR: the self-hosted front end against xcc-fe -g.
# =================================================================
#
# Under -g the lowering stamps each statement's file, line and column on its
# instructions (` !dbg f:l:c`), each function's opening brace on its header,
# and the module header gains the `dbgfile <n> "<path>"` table. fe-diff runs
# both front ends WITHOUT -g, so none of that is compared there; this runs the
# drop-in (selfhost/tools/xtfe.xc) and the reference with -g on the same file
# and wants the same bytes. A location is the statement's own start — the
# port's parser has to put every statement where the reference's does, and its
# file table has to be filled in the same order with the same paths.
#
# Each oracle -g IR is also read back through the PORT's IR parser and printed
# (selfhost/tools/xtirp.xc), which must reproduce it byte for byte: the parser
# side of -g (`dbgfile`, ` !dbg` on instructions and function headers).
#
#   bash selfhost/tools/irdbg-diff.sh [target] [pattern]
#
# target defaults to arm64. The corpus is tests/fixtures, SAMPLED: every 4th
# file by default (about 220), which all-diff runs; IRDBG_STRIDE=1 takes every
# one. A file the ORACLE cannot compile is counted separately and never scored,
# and an oracle file with no location in it at all counts as a FAILURE — that
# would be -g not honoured, and comparing it would be fe-diff over again.
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
XC_HOST_ARCH=${XC_HOST_ARCH:-$( case "$(uname -m)" in (arm64|aarch64) echo arm64 ;; (*) echo x86_64 ;; esac )}
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/$XC_PLAT
[ -x "$BIN/xcc-fe" ] || BIN=bin/linux
TARGET=${1:-arm64}
ORACLE_TARGET=$TARGET
PORT_TARGET=$TARGET
case "$TARGET" in xt|xt6502) ORACLE_TARGET=xt; PORT_TARGET=xt6502 ;; esac
PATTERN=${2:-}
STRIDE=${IRDBG_STRIDE:-4}
WORK=${TMPDIR:-/tmp}/irdbg.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

BUILD_INCS=(-I support/generic/lib -I support/$XC_HOST_ARCH/lib -I support/xt6502/lib
            -I selfhost/lexer -I selfhost/preproc -I selfhost/parser
            -I selfhost/sema -I selfhost/ir -I selfhost/opt)

echo "building xtfe and xtirp (xtc → native $XC_HOST_ARCH)…"
"${XC_TOOL_XCC:-$BIN/xcc}" -O2 -A $XC_HOST_ARCH -o "$WORK/xtfe" selfhost/tools/xtfe.xc -I selfhost/driver \
    "${BUILD_INCS[@]}" 2>&1 | grep -E "^[^ ].*error" && exit 1
"${XC_TOOL_XCC:-$BIN/xcc}" -O2 -A $XC_HOST_ARCH -H . -o "$WORK/xtirp" selfhost/tools/xtirp.xc \
    -I selfhost/ir -I selfhost/opt 2>&1 | grep -E "^[^ ].*error" && exit 1

RUN_INCS=(-I selfhost/lexer -I selfhost/preproc -I selfhost/parser
          -I selfhost/sema -I selfhost/ir -I selfhost/opt)

pass=0; fail=0; unsup=0; oracle=0; fediv=0
rtok=0; rtfail=0
declare -a FAILED
declare -a FEDIV

# SHARD_I/SHARD_N as in the other harnesses: every Nth file, for all-diff's
# parallel slots. The default 0/1 is every file.
FILES=$(find tests/fixtures -name '*.xc' | sort \
        | awk -v s="$STRIDE" 'NR % s == 0' \
        | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')
for f in $FILES; do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
    if ! "$BIN/xcc-fe" -m "$ORACLE_TARGET" -H . "${RUN_INCS[@]}" -g "$f" -o "$WORK/oracle.ir" \
         >/dev/null 2>&1 || [ ! -s "$WORK/oracle.ir" ]; then
        oracle=$((oracle+1)); continue
    fi
    if ! grep -q ' !dbg ' "$WORK/oracle.ir"; then
        fail=$((fail+1)); FAILED+=("$f (the oracle's -g IR has no !dbg)"); continue
    fi
    "$WORK/xtfe" -m "$PORT_TARGET" -H . "${RUN_INCS[@]}" -g "$f" -o "$WORK/port.ir" >/dev/null 2>&1
    rc=$?
    if [ $rc -eq 3 ]; then unsup=$((unsup+1)); FAILED+=("$f (unsupported)"); continue; fi
    if [ $rc -ne 0 ]; then fail=$((fail+1)); FAILED+=("$f (exit $rc)"); continue; fi
    if diff -q "$WORK/oracle.ir" "$WORK/port.ir" >/dev/null; then
        pass=$((pass+1))
    else
        # A file the two front ends already disagree on WITHOUT -g is
        # fe-diff's failure, not this one's: named, not scored either way.
        "$BIN/xcc-fe" -m "$ORACLE_TARGET" -H . "${RUN_INCS[@]}" "$f" -o "$WORK/oracle0.ir" >/dev/null 2>&1
        "$WORK/xtfe" -m "$PORT_TARGET" -H . "${RUN_INCS[@]}" "$f" -o "$WORK/port0.ir" >/dev/null 2>&1
        if ! diff -q "$WORK/oracle0.ir" "$WORK/port0.ir" >/dev/null 2>&1; then
            fediv=$((fediv+1)); FEDIV+=("$f")
        else
            fail=$((fail+1))
            FAILED+=("$f ($(diff "$WORK/oracle.ir" "$WORK/port.ir" | grep -c '^[<>]') lines)")
        fi
    fi
    "$WORK/xtirp" "$WORK/oracle.ir" -o "$WORK/rt.ir" >/dev/null 2>&1
    if [ $? -eq 0 ] && diff -q "$WORK/oracle.ir" "$WORK/rt.ir" >/dev/null; then
        rtok=$((rtok+1))
    else
        rtfail=$((rtfail+1))
        FAILED+=("$f (IR parser round trip)")
    fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- differing (first 25):"
    printf '  %s\n' "${FAILED[@]}" | head -25
fi
if [ "${#FEDIV[@]}" -gt 0 ]; then
    echo "--- differ without -g as well (fe-diff's to fix; NOT compared here):"
    printf '  %s\n' "${FEDIV[@]}"
fi
if [ "$pass" -eq 0 ] && [ "$oracle" -gt 0 ]; then
    echo "!!! the oracle compiled NOTHING for -m $TARGET — is that a target name it knows?"
fi
# `rtfail=` is summed into all-diff's FAIL column with `fail=` (it greps for
# both); `rtok=` is deliberately not spelt `pass=`, or every file would count
# twice.
echo "--- irdbg-diff[$TARGET]: pass=$pass fail=$fail unsupported=$unsup oracle-failed=$oracle" \
     "fe-divergent=$fediv rtok=$rtok rtfail=$rtfail ---"
# A harness that reports failures must also signal them.
[ "$fail" -eq 0 ] && [ "$rtfail" -eq 0 ] || exit 1
# Nothing compared is not a pass (private:docs/bugs/239).
if [ "$pass" -eq 0 ]; then
    echo "--- $(basename "$0"): NOTHING WAS COMPARED — this is not a pass"
    exit 1
fi
