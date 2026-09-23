#!/bin/bash
# xcc-diff.sh — the xtc DRIVER against the Objective-C one, end to end.
#
#   bash selfhost/tools/xcc-diff.sh [LEVEL] [pattern]
#
# Every other harness compares ONE stage. This compares the whole pipeline as a
# user runs it: source in, target file out, byte-for-byte. That is the property
# THE RULE actually asks for — not "the ported back end agrees" but "the ported
# COMPILER produces the same program".
#
# LEVEL is the optimisation level both sides are given, default 0. At -O0 the
# two agree byte-for-byte. At -O3 they do NOT, and that is bug 065 (the ported
# arm64 back end on optimised IR — the same divergence arm64o3-diff reports);
# run this at 3 to watch that close.
#
# Compares the ASM rather than the linked file: the linkers are already covered
# byte-for-byte by ld64-diff and ldandroid-diff, and asm names the divergence in
# a form you can read.
set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx; [ -x "$BIN/xcc" ] || BIN=bin/linux
LEVEL=${1:-0}
PATTERN=${2:-}
WORK=${TMPDIR:-/tmp}/xccdiff.$$
mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT

INCS=(-I support/generic/lib -I support/arm64/lib)
SELF=(-I selfhost/lexer -I selfhost/preproc -I selfhost/parser -I selfhost/sema
      -I selfhost/ir -I selfhost/opt -I selfhost/codegen -I selfhost/asm
      -I selfhost/link -I selfhost/driver)

echo "building xcc.xc (the xtc driver → native arm64)…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xccxc" selfhost/tools/xcc.xc \
    "${INCS[@]}" "${SELF[@]}" > "$WORK/build.log" 2>&1
if [ ! -x "$WORK/xccxc" ]; then
    echo "--- xcc-diff: BROKEN (the driver did not build)"
    sed 's/^/    /' "$WORK/build.log" | head -20
    exit 1
fi

pass=0; fail=0; oracle=0; unsup=0
declare -a FAILED
declare -a UNSUP
# SHARD_I/SHARD_N: every Nth fixture, so all-diff can split this across slots.
# It is the longest harness in the matrix (every fixture, twice, through the
# whole driver), so unsharded it would set the makespan on its own.
FIXTURES=$(ls tests/fixtures/*.xc | sort \
    | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')
# xt6502 joins arm64 and android: the driver wires all three, and the 6502 path
# has the most moving parts of the three (layout, lazy-linked runtime, peephole,
# assembler-as-linker), so it is the one most worth comparing end to end.
for arch in arm64 android xt6502; do
    for f in $FIXTURES; do
        [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
        b=$(basename "$f" .xc)
        # Both outputs are removed FIRST. Without this a run that produces no
        # file is compared against the previous fixture's leftovers: the port
        # refusing a fixture it does not support was reported as a 610-line
        # codegen divergence, which is a wild goose chase, not a result.
        rm -f "$WORK/ref.s" "$WORK/port.s"
        # The ORACLE first: a fixture it cannot build is not a comparison.
        # The 6502 oracle is spelled `-m xt`, not `-A xt6502`, and it resolves
        # its library against support/xt6502 rather than support/arm64.
        if [ "$arch" = xt6502 ]; then
            REFSEL=(-m xt); PORTINC=(-I support/xt6502/lib -I support/generic/lib)
        else
            REFSEL=(-A "$arch"); PORTINC=("${INCS[@]}")
        fi
        if ! "$BIN/xcc" "${REFSEL[@]}" -H . -q "-O$LEVEL" -S -o "$WORK/ref.s" "$f" \
                >/dev/null 2>&1 || [ ! -s "$WORK/ref.s" ]; then
            oracle=$((oracle+1)); continue
        fi
        "$WORK/xccxc" -A "$arch" -H . "${PORTINC[@]}" "-O$LEVEL" -S \
            -o "$WORK/port.s" "$f" >"$WORK/port.log" 2>&1
        if [ ! -s "$WORK/port.s" ]; then
            # A REFUSAL is a known gap in the port, not a divergence — it is
            # counted and named separately so it cannot be mistaken for one.
            why=$(grep -o 'unsupported: .*' "$WORK/port.log" | head -1)
            unsup=$((unsup+1)); UNSUP+=("$arch/$b — ${why:-produced no output}")
            continue
        fi
        if cmp -s "$WORK/ref.s" "$WORK/port.s"; then
            pass=$((pass+1))
        else
            fail=$((fail+1))
            FAILED+=("$arch/$b ($(diff "$WORK/ref.s" "$WORK/port.s" | grep -c '^[<>]') lines)")
        fi
    done
done

echo "--- xcc-diff[-O$LEVEL]: pass=$pass fail=$fail unsupported=$unsup oracle-failed=$oracle ---"
# A harness that REPORTS failures must also SIGNAL them: these printed the
# summary and fell off the end with status 0, which is fine for a human reading
# the table and useless to anything that checks status instead of stdout. The
# final `exit` below does that.
#
# It used to be done HERE, with `[ "$fail" -eq 0 ] || exit 1` on this line —
# above the report. So the moment there WAS a failure the harness exited
# without naming a single file, and the list below was reachable only when
# there was nothing to list. all-diff said "xcc 1458 3 FAIL" and no shard log
# said which three, which is how it was found.
if [ "$fail" -gt 0 ]; then
    echo "--- differing (first 15):"
    printf '  %s\n' "${FAILED[@]}" | head -15
fi
if [ "$unsup" -gt 0 ]; then
    echo "--- the port REFUSED (a gap, not a divergence):"
    printf '  %s\n' "${UNSUP[@]}" | head -10
fi
# oracle-failed are files the REFERENCE could not build: never compared, and
# NOT passes.
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
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
