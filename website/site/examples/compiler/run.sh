#!/bin/bash
# run.sh — compile and run every documentation example, and show its output.
#
# The examples in the compiler docs are all real programs that live here. This
# script builds each one with the installed xcc and prints what it actually
# printed, so a code block in the docs can never drift from what the compiler
# does. Anything that fails to compile is a documentation bug.
#
#   ./run.sh            build + run all, report pass/fail
#   ./run.sh loops      just the ones matching a pattern
#   VERBOSE=1 ./run.sh  show each program's output
set -u
cd "$(dirname "$0")" || exit 1
XCC=${XCC:-/opt/xcc/0.6/bin/xcc}
[ -x "$XCC" ] || XCC=$(command -v xcc) || { echo "no xcc found"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PATTERN=${1:-}
pass=0; fail=0
for src in *.xc; do
    [ -e "$src" ] || continue
    name=${src%.xc}
    [ -n "$PATTERN" ] && case "$name" in *"$PATTERN"*) ;; *) continue ;; esac
    if ! "$XCC" -o "$TMP/$name" "$src" >"$TMP/$name.log" 2>&1; then
        echo "FAIL  $src (compile)"; sed 's/^/      /' "$TMP/$name.log" | head -5
        fail=$((fail+1)); continue
    fi
    if ! "$TMP/$name" >"$TMP/$name.out" 2>&1; then
        echo "FAIL  $src (run)"; sed 's/^/      /' "$TMP/$name.out" | head -5
        fail=$((fail+1)); continue
    fi
    # An .expected file makes the output part of the test, not just a sample.
    if [ -f "$name.expected" ] && ! diff -q "$TMP/$name.out" "$name.expected" >/dev/null; then
        echo "FAIL  $src (output changed)"
        diff "$name.expected" "$TMP/$name.out" | sed 's/^/      /' | head -10
        fail=$((fail+1)); continue
    fi
    pass=$((pass+1))
    if [ "${VERBOSE:-0}" = 1 ]; then
        echo "=== $src ==="; cat "$TMP/$name.out"
    else
        echo "ok    $src"
    fi
done
echo "--- examples: $pass passed, $fail failed ---"
exit $([ $fail -eq 0 ] && echo 0 || echo 1)
