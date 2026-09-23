#!/bin/bash
# lnwasm-diff.sh — the ported wasm binary writer against xcc-ln-wasm32.
# =====================================================================
#
# self-hosting, wasm stage B. The oracle is `xcc-ln-wasm32` over the WAT
# text that `xcc-cg-wasm32 -O0` emits: the .wasm must come out byte for
# byte the same (the .js/.html loader files it also writes are host
# scaffolding and are not compared). Stage A (wasm-diff.sh) pinned the
# WAT itself; this pins the bytes.
#
#   bash selfhost/tools/lnwasm-diff.sh [pattern]

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc-fe" ] || BIN=bin/linux
PATTERN=${1:-}
WORK=${TMPDIR:-/tmp}/lnwasmdiff.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "building xtlnwasm (xtc → native arm64)…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xtlnwasm" selfhost/tools/xtlnwasm.xc \
    -I selfhost/asm 2>&1 | grep -E "^[^ ].*error" && exit 1

RUN_INCS=(-I selfhost/lexer -I selfhost/preproc -I selfhost/parser
          -I selfhost/sema -I selfhost/ir -I selfhost/codegen)

pass=0; fail=0; oracle=0
# VALIDATE the oracle's module, not just compare against it. Two writers
# agreeing byte for byte says nothing about whether either wrote a module a
# runtime will load — the corpus runs under node, so a program it builds is
# checked there, but a library or anything the corpus does not run is not.
# wabt's wasm-validate is the reference decoder; when it is installed every
# oracle .wasm goes through it and an invalid one is a NAMED failure
# (task #73). Without it the run says so, once, up front.
VALIDATE=$(command -v wasm-validate || true)
if [ -n "$VALIDATE" ]; then echo "validating every oracle module with $VALIDATE"
else echo "wasm-validate NOT FOUND — modules compared, not validated (brew install wabt)"; fi
invalid=0
declare -a INVALID
declare -a FAILED

# SHARD_I/SHARD_N: run only every Nth file, so one harness can be split
# across several parallel slots. all-diff uses it on the long ones; the
# default 0/1 is every file, which is what a direct run gets.
FILES=$(find tests support selfhost -name '*.xc' -not -path 'tests/fuzz/findings/*' | sort | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')
for f in $FILES; do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
    if ! "$BIN/xcc-fe" -A wasm32 -H . "${RUN_INCS[@]}" "$f" -o "$WORK/a.ir" \
         >/dev/null 2>&1 || [ ! -s "$WORK/a.ir" ]; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$BIN/xcc-cg-wasm32" -O0 -q -o "$WORK/a.wat" "$WORK/a.ir" >/dev/null 2>&1; then
        oracle=$((oracle+1)); continue
    fi
    rm -f "$WORK/a.wasm" "$WORK/b.wasm"
    if ! "$BIN/xcc-ln-wasm32" "$WORK/a.wat" "$WORK/a" -q >/dev/null 2>&1 \
         || [ ! -s "$WORK/a.wasm" ]; then
        oracle=$((oracle+1)); continue
    fi
    if [ -n "$VALIDATE" ] && ! "$VALIDATE" "$WORK/a.wasm" >"$WORK/v.err" 2>&1; then
        invalid=$((invalid+1)); fail=$((fail+1))
        INVALID+=("$f: $(head -1 "$WORK/v.err" | cut -c1-100)")
        continue
    fi
    "$WORK/xtlnwasm" "$WORK/a.wat" -o "$WORK/b.wasm" >/dev/null 2>&1
    rc=$?
    if [ $rc -ne 0 ]; then fail=$((fail+1)); FAILED+=("$f (exit $rc)"); continue; fi
    if cmp -s "$WORK/a.wasm" "$WORK/b.wasm"; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        FAILED+=("$f ($(cmp "$WORK/a.wasm" "$WORK/b.wasm" 2>&1 | head -1 \
            | sed 's/^.*differ: /differ: /'))")
    fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- differing (first 15):"
    printf '  %s\n' "${FAILED[@]}" | head -15
fi
if [ "${#INVALID[@]}" -gt 0 ]; then
    echo "--- the ORACLE wrote an INVALID module for these (wasm-validate):"
    printf '  %s\n' "${INVALID[@]}"
fi
echo "--- lnwasm-diff: pass=$pass fail=$fail oracle-failed=$oracle invalid=$invalid ---"
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

