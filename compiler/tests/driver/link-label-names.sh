#!/bin/bash
# link-label-names.sh — a multi-file link renames local LABELS only (#290).
# Joining assembly texts renames each file's `.L<rest>` to `.L<i>Z<rest>`; it
# rewrote every `.L` byte pair, so a -g build whose source path has `.L` in it
# (`x.Logs/prog.xc`) recorded `x.L1Zogs/prog.xc`, and a string literal holding
# `.L` was changed too. An x86-64 link (several texts: the runtime's and the
# program's) keeps both as written; the two compilers alike.
#
#   bash tests/driver/link-label-names.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/x.Logs"
printf '#import "Stdio.xc"\ni32 main(void) { Stdio.printf("key a.Lb here\\n"); return 0; }\n' > "$W/x.Logs/prog.xc"
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    n=$(basename "$c")
    "$c" -q -g -O0 -A x86_64 -H . -o "$W/p.$n" "$W/x.Logs/prog.xc" > "$W/e" 2>&1 || { echo "FAIL $n: no build: $(head -c 300 "$W/e")"; fail=1; continue; }
    strings "$W/p.$n" | grep -q 'key a\.Lb here' || { echo "FAIL $n: the string literal's .L was rewritten"; fail=1; }
    strings "$W/p.$n" | grep -q 'x\.Logs' || { echo "FAIL $n: the source path's .L was rewritten in the debug info"; fail=1; }
    strings "$W/p.$n" | grep -q 'x\.L[0-9]*Zogs\|a\.L[0-9]*Zb' && { echo "FAIL $n: a renamed .L inside a path or string"; fail=1; }
done
[ $fail = 0 ] && echo "link-label-names: ok"
exit $fail
