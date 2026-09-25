#!/bin/bash
# bin-diff.sh — the two DRIVERS' linked files, byte for byte, every host target.
#
#   bash selfhost/tools/bin-diff.sh [pattern]
#
# BIN_DIFF_TARGETS picks the targets (6502 is not in the default set) and
# BIN_DIFF_FLAGS adds options to both drivers, e.g.
# BIN_DIFF_TARGETS=6502 BIN_DIFF_FLAGS="-Q loop".
#
# xcc-diff compares the drivers' ASSEMBLY and the ld*-diffs compare the LINKERS
# given one input. Neither sees what a driver hands its linker or how it calls
# it — which is exactly where 128 (m68k crt0 prepended), 133 (the port's musl
# pull) and 137 (the port stamped ios-sim binaries as macOS) all lived, each
# found by building one fixture with both drivers by hand. This is that check,
# run over every fixture and every target both drivers link in-house.
#
# An ORACLE failure (the reference cannot build it — no SDK, no pool, a
# target= the fixture refuses) is counted and NOT a pass. A port REFUSAL is a
# gap, named separately from a divergence.
set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx; [ -x "$BIN/xcc" ] || BIN=bin/linux
PATTERN=${1:-}
WORK=${TMPDIR:-/tmp}/bindiff.$$
mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT

SELF=(-I selfhost/lexer -I selfhost/preproc -I selfhost/parser -I selfhost/sema
      -I selfhost/ir -I selfhost/opt -I selfhost/codegen -I selfhost/asm
      -I selfhost/link -I selfhost/driver)
echo "building xcc.xc (the xtc driver → native arm64)…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xccxc" selfhost/tools/xcc.xc \
    "${SELF[@]}" > "$WORK/build.log" 2>&1
if [ ! -x "$WORK/xccxc" ]; then grep -a error "$WORK/build.log" | head -5; exit 1; fi

pass=0; fail=0; unsup=0; oracle=0
declare -a FAILED UNSUP
FIXTURES=$(ls tests/fixtures/*.xc | sort \
    | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')
# Every target whose whole pipeline — assemble, link, write — is in-house in
# BOTH drivers. ios-sim and ios (device) are the arm64 back end with the iOS
# stamp; ios-sim needs the iPhoneSimulator SDK's .tbd stubs (without Xcode it
# is all oracle-failed, the honest number), while ios (device, PLATFORM_IOS)
# links against no SDK for a console program, so it compares like arm64 — the
# device build is Mac-free and byte-identical between the drivers, which is
# what a human's on-device step relies on before it even reaches the keychain.
TARGETS=${BIN_DIFF_TARGETS:-"arm64 ios-sim ios x86_64 win64 android"}
read -r -a EXTRA <<< "${BIN_DIFF_FLAGS:-}"
for arch in $TARGETS; do
    for f in $FIXTURES; do
        [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
        b=$(basename "$f" .xc)
        rm -f "$WORK/ref.bin" "$WORK/port.bin"
        if ! "$BIN/xcc" -A "$arch" -H . -q ${EXTRA[@]+"${EXTRA[@]}"} -o "$WORK/ref.bin" "$f" >/dev/null 2>&1 \
             || [ ! -s "$WORK/ref.bin" ]; then
            oracle=$((oracle+1)); continue
        fi
        "$WORK/xccxc" -A "$arch" -H . -q ${EXTRA[@]+"${EXTRA[@]}"} -o "$WORK/port.bin" "$f" >"$WORK/port.log" 2>&1
        if [ ! -s "$WORK/port.bin" ]; then
            why=$(grep -o 'error: .*' "$WORK/port.log" | head -1)
            unsup=$((unsup+1)); UNSUP+=("$arch/$b — ${why:-produced no output}")
            continue
        fi
        if cmp -s "$WORK/ref.bin" "$WORK/port.bin"; then
            pass=$((pass+1))
        else
            fail=$((fail+1))
            FAILED+=("$arch/$b ($(cmp -l "$WORK/ref.bin" "$WORK/port.bin" 2>/dev/null | wc -l | tr -d ' ') bytes, $(stat -f%z "$WORK/ref.bin" 2>/dev/null || stat -c%s "$WORK/ref.bin") vs $(stat -f%z "$WORK/port.bin" 2>/dev/null || stat -c%s "$WORK/port.bin"))")
        fi
    done
done

echo "--- bin-diff: pass=$pass fail=$fail unsupported=$unsup oracle-failed=$oracle ---"
if [ "$fail" -gt 0 ]; then
    echo "--- differing (first 15):"; printf '  %s\n' "${FAILED[@]}" | head -15
fi
if [ "$unsup" -gt 0 ]; then
    echo "--- the port REFUSED (a gap, not a divergence):"; printf '  %s\n' "${UNSUP[@]}" | head -10
fi
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
