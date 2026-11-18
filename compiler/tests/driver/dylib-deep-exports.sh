#!/bin/bash
# dylib-deep-exports.sh — the driver reads every export of a dylib it links
# against, however deep its export trie (#334). The trie reader stopped at
# depth 64, so in a library whose names nest (each one a prefix of the
# next, one trie level per name) the names below level 64 were never read,
# and a program calling one did not link. Here 90 nested names; the
# program calls the deepest.
#
#   bash tests/driver/dylib-deep-exports.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
XC=${XC:-bin/osx/xcc-xc}; case $XC in /*) ;; *) XC="$(pwd)/$XC";; esac
[ "$(uname -s)-$(uname -m)" = Darwin-arm64 ] || { echo "dylib-deep-exports: skipped (macOS arm64 only)"; exit 0; }
command -v clang > /dev/null || { echo "dylib-deep-exports: skipped (no clang)"; exit 0; }
ROOT=$(pwd)
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
n=f; deepest=
for i in $(seq 1 90); do n="${n}a"; printf 'int %s(void) { return %d; }\n' "$n" "$i"; deepest=$n; done > "$W/deep.c"
clang -dynamiclib -o "$W/libdeep.dylib" "$W/deep.c" -install_name @rpath/libdeep.dylib 2> "$W/e" \
    || { echo "dylib-deep-exports: skipped (clang could not build the dylib)"; exit 0; }
cat > "$W/use.xc" <<XC
#import "Stdio.xc"
i32 $deepest(void);
i32 main(void)
    {
    Stdio.printf("%d\n", $deepest());
    return 0;
    }
XC
fail=0
if ( cd "$W" && "$XC" -q -O2 -H "$ROOT" -L . -ldeep -o use use.xc ) > "$W/e" 2>&1; then
    got=$(cd "$W" && DYLD_LIBRARY_PATH="$W" ./use 2>&1)
    [ "$got" = 90 ] || { echo "FAIL dylib-deep-exports: the program prints '$got', want 90"; fail=1; }
else
    echo "FAIL dylib-deep-exports: a call to the deepest export does not link: $(head -c 300 "$W/e")"; fail=1
fi
[ $fail = 0 ] && echo "dylib-deep-exports: ok"
exit $fail
