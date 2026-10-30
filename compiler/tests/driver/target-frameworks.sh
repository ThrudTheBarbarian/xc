#!/bin/bash
# target-frameworks.sh — `#import <CoreFoundation>` names an Apple framework on
# macOS, and on android is not found, in both compilers (target table,
# 2026-10-30)
#
# Frameworks follow the row's Apple SDK. android is the arm64 back end but has
# no SDK, and both compilers used to search the macOS one for it (a latent bug
# from when the front end saw android as plain arm64).
#
#   bash tests/driver/target-frameworks.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
[ "$(uname -s)" = Darwin ] || { echo "target-frameworks: skipped (not macOS)"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
printf '#import <CoreFoundation>\ni32 main(i32 argc, u8** argv) { return 0; }\n' > "$W/cf.xc"
for c in "$REF" "$XC"; do
    n=$(basename "$c")
    "$c" -q -A arm64 -S -o "$W/m.s" "$W/cf.xc" > "$W/e" 2>&1 \
        || { echo "FAIL target-frameworks: $n -A arm64 does not find CoreFoundation: $(head -c 160 "$W/e")"; fail=1; }
    "$c" -q -A android -S -o "$W/a.s" "$W/cf.xc" > "$W/e" 2>&1 \
        && { echo "FAIL target-frameworks: $n -A android took CoreFoundation from the macOS SDK"; fail=1; }
    grep -q "Cannot find include file 'CoreFoundation'" "$W/e" \
        || { echo "FAIL target-frameworks: $n -A android: not the missing-include error: $(head -c 160 "$W/e")"; fail=1; }
done
[ $fail = 0 ] && echo "target-frameworks: ok"
exit $fail
