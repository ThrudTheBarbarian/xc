#!/bin/bash
# missing-value.sh — a flag that takes a value, given none, says so (#337):
# `xcc -o` reported "unrecognised option '-o'", where the reference driver
# says "-o requires an argument". Both drivers now say the same line, the
# flag named as the reference names it (`--output` as -o).
#
#   bash tests/driver/missing-value.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
fail=0
for f in -o -I -L -A -D -m --output --include; do
    mx=$("$XC" $f 2>&1 | head -1)
    case "$mx" in *"requires an argument"*) ;; *) echo "FAIL $f: '$mx'"; fail=1 ;; esac
    if [ -x "$REF" ]; then
        mr=$("$REF" $f 2>&1 | head -1)
        [ "$mx" = "$mr" ] || { echo "FAIL $f: the drivers differ: '$mx' / '$mr'"; fail=1; }
    fi
done
[ $fail = 0 ] && echo "missing-value: ok"
exit $fail
