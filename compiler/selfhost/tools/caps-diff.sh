#!/bin/bash
# caps-diff.sh — the two DRIVERS' output under the capability flags.
#
#   bash selfhost/tools/caps-diff.sh [pattern]
#
# bin-diff builds every fixture with each driver's DEFAULT options. The flags
# that change what is built — the m68k CPU, FPU and PIC model, atomic ARC,
# mimalloc, the Android DT_NEEDED list, a library build — each take a path
# through the driver the defaults never reach, so they get their own
# comparison: one sample of the fixtures, built by both drivers under each flag
# set, compared byte for byte.
#
# An ORACLE failure (the reference cannot build it) is counted and NOT a pass.
# A port refusal is a gap, named separately from a divergence.
set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx; [ -x "$BIN/xcc" ] || BIN=bin/linux
PATTERN=${1:-}
WORK=${TMPDIR:-/tmp}/capsdiff.$$
mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT

SELF=(-I selfhost/lexer -I selfhost/preproc -I selfhost/parser -I selfhost/sema
      -I selfhost/ir -I selfhost/opt -I selfhost/codegen -I selfhost/asm
      -I selfhost/link -I selfhost/driver)
echo "building xcc.xc (the xtc driver → native arm64)…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xccxc" selfhost/tools/xcc.xc \
    "${SELF[@]}" > "$WORK/build.log" 2>&1
if [ ! -x "$WORK/xccxc" ]; then grep -a error "$WORK/build.log" | head -5; exit 1; fi

# One fixture in sixteen: the flags change a handful of decisions each, and a
# spread of programs exercises them; the defaults are bin-diff's job.
FIXTURES=$(ls tests/fixtures/*.xc | sort | awk 'NR % 16 == 0' \
    | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')

# Each set is one line: an output extension, then the flags.
SETS=(".prg -A 68000"
      ".prg -A 68030"
      ".prg -A m68k -mhard-float"
      ".prg -A 68030 -mfpu"
      ".prg -A m68k -mpic"
      ".prg -A 68030 -fPIC"
      "-fthread-safe-arc"
      "-fno-thread-safe-arc"
      "-A x86_64 -fthread-safe-arc"
      "-A x86_64 -fno-thread-safe-arc"
      "-A android -fthread-safe-arc"
      "-A x86_64 -fmalloc=mimalloc"
      "-A android --needed libfoo.so"
      ".apk -A android --emit-apk --needed libfoo.so --lib-name main"
      ".so -A android --emit-lib"
      "-falloc=heap -fmalloc=system")

pass=0; fail=0; unsup=0; oracle=0
declare -a FAILED UNSUP
for set in "${SETS[@]}"; do
    ext=""
    case "$set" in .*) ext=${set%% *}; set=${set#* } ;; esac
    # shellcheck disable=SC2206
    flags=($set)
    for f in $FIXTURES; do
        [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
        b=$(basename "$f" .xc)
        # One output NAME for both drivers: a library's soname and an APK's
        # package are taken from it.
        mkdir -p "$WORK/r" "$WORK/p"
        out="lib$b$ext"
        rm -f "$WORK/r/$out" "$WORK/p/$out"
        if ! "$BIN/xcc" -H . -q "${flags[@]}" -o "$WORK/r/$out" "$f" >/dev/null 2>&1 \
             || [ ! -s "$WORK/r/$out" ]; then
            oracle=$((oracle+1)); continue
        fi
        "$WORK/xccxc" -H . -q "${flags[@]}" -o "$WORK/p/$out" "$f" >"$WORK/port.log" 2>&1
        if [ ! -s "$WORK/p/$out" ]; then
            why=$(grep -o 'error: .*' "$WORK/port.log" | head -1)
            unsup=$((unsup+1)); UNSUP+=("[$set] $b — ${why:-produced no output}")
            continue
        fi
        if cmp -s "$WORK/r/$out" "$WORK/p/$out"; then
            pass=$((pass+1))
        else
            fail=$((fail+1))
            FAILED+=("[$set] $b ($(cmp -l "$WORK/r/$out" "$WORK/p/$out" 2>/dev/null | wc -l | tr -d ' ') bytes)")
        fi
    done
done

echo "--- caps-diff: pass=$pass fail=$fail unsupported=$unsup oracle-failed=$oracle ---"
if [ "$fail" -gt 0 ]; then
    echo "--- differing (first 15):"; printf '  %s\n' "${FAILED[@]}" | head -15
fi
if [ "$unsup" -gt 0 ]; then
    echo "--- the port REFUSED (a gap, not a divergence):"; printf '  %s\n' "${UNSUP[@]}" | head -10
fi
if [ "$pass" -eq 0 ]; then
    echo "--- $(basename "$0"): NOTHING WAS COMPARED — this is not a pass"
    exit 1
fi
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
