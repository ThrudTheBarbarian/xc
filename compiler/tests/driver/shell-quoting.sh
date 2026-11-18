#!/bin/bash
# shell-quoting.sh — every argument the driver hands a shell is quoted by one
# rule (#337): a C source in a directory whose name has a space and a quote
# builds and runs. (The Windows half of the rule, double quotes with \" and
# doubled backslashes before a quote, is exercised by the win64 C builds.)
#
#   bash tests/driver/shell-quoting.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
command -v clang > /dev/null || { echo "shell-quoting: no clang, skipped"; exit 0; }
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
D="$W/it's a dir"
mkdir -p "$D"
printf '#include <stdio.h>\nint main(void) { printf("ok\\n"); return 0; }\n' > "$D/p.c"
"$XC" -q -O2 -o "$D/p" "$D/p.c" > "$W/e" 2>&1 || { echo "FAIL shell-quoting: a source under a spaced, quoted name does not build: $(head -c 300 "$W/e")"; fail=1; }
[ -x "$D/p" ] && [ "$("$D/p")" = ok ] || { echo "FAIL shell-quoting: the program does not run"; fail=1; }
[ $fail = 0 ] && echo "shell-quoting: ok"
exit $fail
