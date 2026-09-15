#!/bin/bash
# iface-diff.sh — the ported front end against the original on fixtures that
# IMPORT AN INTERFACE (separate-compilation stage 3, and §4.2/§4.3b categories
# on external classes).
# =========================================================================
#
# Every other differential compiles each file ALONE, which silently skips a
# fixture that needs an import — the green-while-untested trap this harness
# exists to close: the self-hosted compiler "supported" categories while being
# unable to meet one on an external class at all.
#
# The module fixtures (tests/selfhost-iface/mod-*.xc) are compiled with
# `xcc -c` first, leaving their .xtc.iface files in the work dir; each client
# fixture (use-*.xc) is then compiled by BOTH front ends against them and the
# IR text compared BYTE FOR BYTE.
#
#   bash selfhost/tools/iface-diff.sh [pattern]
set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc-fe" ] || BIN=bin/linux
PATTERN=${1:-}
WORK=${TMPDIR:-/tmp}/ifacediff.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "building xtfe (xtc → native arm64)…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xtfe" selfhost/tools/xtfe.xc -I selfhost/driver \
    -I selfhost/lexer -I selfhost/preproc -I selfhost/parser \
    -I selfhost/sema -I selfhost/ir 2>&1 | grep -E "^[^ ].*error" && exit 1

for m in tests/selfhost-iface/mod-*.xc; do
    b="$(basename "$m" .xc)"
    "$BIN/xcc" -q -A arm64 -c "$m" -o "$WORK/$b.o" 2>"$WORK/$b.err" || {
        echo "BROKEN: module '$b' does not compile:"; cat "$WORK/$b.err"; exit 1; }
done

INCS=(-I support/arm64/lib -I support/generic/lib)
pass=0; fail=0; FAILED=()
for f in tests/selfhost-iface/use-*.xc; do
    b="$(basename "$f" .xc)"
    [ -n "$PATTERN" ] && [[ "$b" != *"$PATTERN"* ]] && continue
    if ! "$BIN/xcc-fe" -L "$WORK" "${INCS[@]}" "$f" -o "$WORK/$b.ref.ir" 2>"$WORK/$b.referr"; then
        echo "ORACLE FAILED  $f: $(tail -1 "$WORK/$b.referr")"; fail=$((fail+1)); FAILED+=("$b"); continue
    fi
    if ! "$WORK/xtfe" -m arm64 "${INCS[@]}" -L "$WORK" "$f" -o "$WORK/$b.port.ir" 2>"$WORK/$b.porterr"; then
        echo "PORT FAILED    $f: $(tail -1 "$WORK/$b.porterr")"; fail=$((fail+1)); FAILED+=("$b"); continue
    fi
    if diff -q "$WORK/$b.ref.ir" "$WORK/$b.port.ir" >/dev/null 2>&1; then
        pass=$((pass+1))
    else
        fail=$((fail+1)); FAILED+=("$b")
    fi
done
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "--- differing (first 10):"
    for b in "${FAILED[@]:0:10}"; do echo "  $b"; done
fi
echo "--- iface-diff: pass=$pass fail=$fail ---"
# A harness that REPORTS failures must also SIGNAL them. These printed the
# summary and fell off the end with status 0, which is fine for a human
# reading the table and useless to CI, to `&&` chains, and to anything else
# that checks status instead of stdout.  FAILS -> non-zero.
[ "$fail" -eq 0 ] || exit 1
[ $fail -eq 0 ]
