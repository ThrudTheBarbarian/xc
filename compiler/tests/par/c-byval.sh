#!/bin/bash
# c-byval.sh — C structs passed by value on x86-64 System V's stack (`byval`)
# between functions xcc compiles and clang's (2026-11-27). The reader passes
# such a struct as the value it copies, marked on the callee's symbol, and
# the x86-64 back end puts it whole on the stack at an offset of its
# alignment, whatever registers are left; a byval parameter is copied from
# there. An over-aligned one (above 16), one through a pointer and one to a
# variadic function stay clang's.
#
# tests/par/c-byval/byval.c must print clang's output, serially and with
# --par-style=auto, and leave to clang exactly the functions it means to.
# Elsewhere than x86-64 System V there is no byval in clang's IR, and the
# program only checks its output. Skipped without clang.
#
#   bash tests/par/c-byval.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang --version >/dev/null 2>&1; then echo "--- c-byval: skipped (no clang) ---"; exit 0; fi
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/par/c-byval/byval.c
fail=0
clang -O2 -o "$W/ref" "$F" || { echo "FAIL c-byval: clang does not build it"; exit 1; }
want=$("$W/ref")
for how in serial auto; do
    st=""; [ $how = auto ] && st="--par-style=auto"
    XC_C_TRACE=1 "$XC" -q -O2 $st -H . -o "$W/x" "$F" > "$W/b" 2>&1 || { echo "FAIL c-byval ($how): does not build"; grep -v warning "$W/b" | head -3; fail=1; continue; }
    got=$(XC_PAR=cpu "$W/x" 2>&1)
    [ "$got" = "$want" ] || { echo "FAIL c-byval ($how): gives '$got', clang's '$want'"; fail=1; }
    if [ "$(uname -m)" = x86_64 ] && [ "$(uname -s)" = Linux ]; then
        left=$(grep -o 'left to clang: @[A-Za-z_0-9]*' "$W/b" | sed 's/.*@//' | sort -u | tr '\n' ' ')
        [ "$left" = "dcall fcall fd fe ff " ] || { echo "FAIL c-byval ($how): left to clang: '$left', not 'dcall fcall fd fe ff '"; fail=1; }
    fi
done
[ $fail = 0 ] && echo "--- c-byval: pass ---" || echo "--- c-byval: FAIL ---"
exit $fail
