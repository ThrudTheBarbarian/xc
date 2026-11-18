#!/bin/bash
# redefinition.sh — two definitions of one function with the same parameter
# types are an error naming both places, whether the second comes from a file
# the program imports or from the same file (#418). The self-hosted compiler
# accepted both: -O0 failed at assembly ("duplicate label"), -O2 kept the
# import's body. Both compilers must give the same message.
#
#   bash tests/driver/redefinition.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}; case $XC in /*) ;; *) XC="$ROOT/$XC";; esac
REF=${REF:-bin/$PLAT/xcc}; case $REF in /*) ;; *) REF="$ROOT/$REF";; esac
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
printf 'float twice(float x) { return x * 2.0; }\n' > "$W/dup_a.xc"
printf '#import <Stdio.xc>\n#import "dup_a.xc"\nfloat twice(float x) { return x * 3.0; }\ni32 main(i32 argc, u8** argv) { Stdio.printf("%%d\\n", (i32)twice(1.0)); return 0; }\n' > "$W/imported.xc"
printf '#import <Stdio.xc>\nfloat twice(float x) { return x * 2.0; }\nfloat twice(float x) { return x * 3.0; }\ni32 main(i32 argc, u8** argv) { Stdio.printf("%%d\\n", (i32)twice(1.0)); return 0; }\n' > "$W/same.xc"
fail=0
for f in imported same; do
    for O in O0 O2; do
        for c in "$XC" "$REF"; do
            n=$(basename "$c")
            if ( cd "$W" && "$c" -q -$O -H "$ROOT" -o t "$f.xc" ) > "$W/$n.$f.$O" 2>&1; then
                echo "FAIL redefinition: $n -$O accepted $f.xc"; fail=1; continue
            fi
            grep -q "Redefinition of 'twice' with same parameter types (previously defined at" "$W/$n.$f.$O" \
                || { echo "FAIL redefinition: $n -$O $f.xc: $(grep -m1 error "$W/$n.$f.$O")"; fail=1; }
        done
        [ -x "$REF" ] && ! diff -q <(grep error "$W/$(basename "$XC").$f.$O") <(grep error "$W/$(basename "$REF").$f.$O") > /dev/null \
            && { echo "FAIL redefinition: the compilers differ on $f.xc -$O:"; grep error "$W/$(basename "$XC").$f.$O" "$W/$(basename "$REF").$f.$O"; fail=1; }
    done
done
[ $fail = 0 ] && echo "redefinition: ok"
exit $fail
