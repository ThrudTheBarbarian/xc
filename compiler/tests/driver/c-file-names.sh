#!/bin/bash
# c-file-names.sh — a C compile names its source, not a scratch file (#349).
# The C path lowers a stub of imports from a scratch file whose name carries
# the process id, and that path went into the assembly's .file directives and
# the -g line table: the same .c gave different -S output every run, and the
# debug lines named a file deleted after the compile. Now -S and -g -S are the
# same run to run, no scratch name appears, and the line table names the .c.
#
#   bash tests/driver/c-file-names.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
command -v clang > /dev/null || { echo "c-file-names: no clang, skipped"; exit 0; }
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
printf '#include <stdio.h>\nint sq(int x) { return x * x; }\nint main(void) { printf("%%d\\n", sq(7)); return 0; }\n' > "$W/a.c"
for g in "" -g; do
    "$XC" -q -O2 $g -S -o "$W/1.s" "$W/a.c" && "$XC" -q -O2 $g -S -o "$W/2.s" "$W/a.c" || { echo "FAIL c-file-names: no assembly ($g)"; fail=1; continue; }
    cmp -s "$W/1.s" "$W/2.s" || { echo "FAIL c-file-names: two $g -S runs of one .c differ"; fail=1; }
    grep -q 'xcc-c-' "$W/1.s" && { echo "FAIL c-file-names: the scratch file is named in the $g assembly"; fail=1; }
done
grep -q '\.file .*"[^"]*/a\.c"' "$W/1.s" || { echo "FAIL c-file-names: the line table does not name a.c"; fail=1; }
[ $fail = 0 ] && echo "c-file-names: ok"
exit $fail
