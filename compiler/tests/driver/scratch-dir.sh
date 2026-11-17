#!/bin/bash
# scratch-dir.sh — each run's scratch files live in one private directory
# under $TMPDIR, removed however the run ends (#337). The driver used
# $TMPDIR/xcc-<pid> (adopting one that was already there) and, for C,
# /tmp/xcc-c-<pid> regardless of $TMPDIR, and an early exit left them.
# With TMPDIR set to an empty directory: a C compile that works, and one
# that fails, leave it empty; -V (--verbose) keeps the run's xcc-* directory.
#
#   bash tests/driver/scratch-dir.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
command -v clang > /dev/null || { echo "scratch-dir: no clang, skipped"; exit 0; }
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/tmp"
printf '#include <stdio.h>\nint main(void) { printf("ok\\n"); return 0; }\n' > "$W/ok.c"
printf 'int main(void) { return 0 }\n' > "$W/bad.c"
before=$(ls -d /tmp/xcc-c-* 2>/dev/null | wc -l)
TMPDIR="$W/tmp" "$XC" -q -O2 -o "$W/ok" "$W/ok.c" > "$W/e" 2>&1 || { echo "FAIL scratch-dir: the C program does not build: $(head -c 300 "$W/e")"; fail=1; }
[ -z "$(ls -A "$W/tmp")" ] || { echo "FAIL scratch-dir: a build left $(ls -A "$W/tmp" | head -3 | tr '\n' ' ')in TMPDIR"; fail=1; }
TMPDIR="$W/tmp" "$XC" -q -O2 -o "$W/bad" "$W/bad.c" > /dev/null 2>&1 && { echo "FAIL scratch-dir: the broken C program built"; fail=1; }
[ -z "$(ls -A "$W/tmp")" ] || { echo "FAIL scratch-dir: a failed build left $(ls -A "$W/tmp" | head -3 | tr '\n' ' ')in TMPDIR"; fail=1; }
after=$(ls -d /tmp/xcc-c-* 2>/dev/null | wc -l)
[ "$after" -le "$before" ] || { echo "FAIL scratch-dir: the runs left $((after - before)) /tmp/xcc-c-* file(s), outside TMPDIR"; fail=1; }
TMPDIR="$W/tmp" "$XC" -V -O2 -o "$W/ok" "$W/ok.c" > /dev/null 2>&1
ls -d "$W/tmp"/xcc-* > /dev/null 2>&1 || { echo "FAIL scratch-dir: -V did not keep the run's scratch directory under TMPDIR"; fail=1; }
[ $fail = 0 ] && echo "scratch-dir: ok"
exit $fail
