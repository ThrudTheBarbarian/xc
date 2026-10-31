#!/bin/bash
# no-output.sh — `xcc prog.xc` with no -o prints the assembly (2026-10-31)
#
# The reference writes a program's assembly to standard output when no -o is
# given (and with -S and no -o). The shipped compiler took a missing -o for a
# program to link, went on to write it to no path and died with SIGSEGV —
# every release since 0.86 at least. Both compilers must exit 0 and print the
# same assembly, plain and with -S.
#
#   bash tests/driver/no-output.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/float_const_fold.xc
fail=0
for flag in "" "-S"; do
    for s in r x; do
        c=$REF; [ $s = x ] && c=$XC
        (cd "$W" && "$OLDPWD/$c" -q -O2 -H "$OLDPWD" $flag "$OLDPWD/$F" > "$W/$s.s" 2> "$W/$s.e")
        rc=$?
        [ $rc = 0 ] || { echo "FAIL no-output: $(basename "$c") $flag exits $rc: $(head -c 200 "$W/$s.e")"; fail=1; }
        grep -q '_main:' "$W/$s.s" || { echo "FAIL no-output: $(basename "$c") $flag printed no assembly"; fail=1; }
    done
    [ $fail = 0 ] && { cmp -s "$W/r.s" "$W/x.s" || { echo "FAIL no-output: the two compilers print different assembly ($flag)"; fail=1; }; }
    [ -e "$W/a.out" ] && { echo "FAIL no-output: a program was linked ($flag)"; fail=1; }
done
[ $fail = 0 ] && echo "no-output: ok"
exit $fail
