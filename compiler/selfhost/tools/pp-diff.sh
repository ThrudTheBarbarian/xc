#!/bin/bash
# pp-diff.sh — the M5 differential test: the xtc preprocessor must agree with the
# Objective-C one, byte for byte, on every input we have.
#
#   selfhost/tools/pp-diff.sh              # every fixture + every library source
#   selfhost/tools/pp-diff.sh a.xc b.xc    # just these files
#   VERBOSE=1 selfhost/tools/pp-diff.sh    # show the first differing lines
#
# Both sides are given the SAME -I paths and nothing else: no implicit platform
# prelude, no automatic support/ directories, no library paths. A file whose
# imports cannot be resolved therefore fails identically on both sides, which is
# still a valid comparison — what is being tested is the preprocessor, not the
# driver's search-path policy.
set -u
cd "$(dirname "$0")/../.." || exit 1

XTC=bin/osx/xcc
FE=bin/osx/xcc-fe
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The library directories a fixture's `#import "Foundation.xc"` needs. generic
# first, then the arm64 platform lib (Stdio/Files/Process), mirroring the order
# the driver itself uses for a native build.
# Every platform's lib — a fixture may import an Atari-only System.xc or a
# win64 interface, and an unresolved import is a hard error on both sides now.
INCS=(-I support/generic/lib -I support/arm64/lib -I support/xt6502/lib
      -I support/arm9/lib -I support/atarist/lib -I support/x86_64/lib
      -I support/win64/lib -I support/win64/selfhost-iface -I support/6502/lib
      -I selfhost/lexer -I selfhost/preproc -I selfhost/parser)

if [ ! -x "$XTC" ] || [ ! -x "$FE" ]; then
    echo "pp-diff: build first (make)" >&2
    exit 1
fi

echo "building xtpp (xtc → native arm64)…"
if ! "$XTC" -H . -q -A arm64 -I selfhost/preproc selfhost/tools/xtpp.xc -o "$TMP/xtpp" 2>"$TMP/build.err"; then
    echo "pp-diff: xtpp failed to build" >&2
    cat "$TMP/build.err" >&2
    exit 1
fi

if [ $# -gt 0 ]; then
    files=("$@")
else
    files=()
    while IFS= read -r f; do files+=("$f"); done < <(
        find tests/fixtures support selfhost -name '*.xc' | sort \
        | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i'
    )
fi

pass=0; fail=0; oracle_failed=0
failed_files=()
for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    "$FE" --dump-pp "$f" "${INCS[@]}" > "$TMP/oracle.txt" 2>"$TMP/oracle.err"
    orc=$?
    "$TMP/xtpp" "${INCS[@]}" "$f" > "$TMP/port.txt" 2>/dev/null
    if [ "$orc" != 0 ]; then
        # The oracle could not expand the file — an unresolvable import, almost
        # always. Named rather than counted as agreement (#836).
        oracle_failed=$((oracle_failed+1))
        echo "  ORACLE FAILED  $f: $(head -1 "$TMP/oracle.err" | tr -d '\033')" >&2
    elif diff -q "$TMP/oracle.txt" "$TMP/port.txt" >/dev/null; then
        pass=$((pass+1))
    else
        fail=$((fail+1)); failed_files+=("$f")
        echo "FAIL  $f ($(diff "$TMP/oracle.txt" "$TMP/port.txt" | grep -c '^[<>]') differing lines)"
        if [ "${VERBOSE:-0}" = "1" ]; then
            diff "$TMP/oracle.txt" "$TMP/port.txt" | head -20 | sed 's/^/      /'
        fi
    fi
done

echo "--- pp-diff: pass=$pass fail=$fail oracle-failed=$oracle_failed ---"
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

[ "$fail" = 0 ]
