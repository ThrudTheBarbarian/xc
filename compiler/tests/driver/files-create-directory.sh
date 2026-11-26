#!/bin/bash
# files-create-directory.sh — Files.createDirectory answers whether the
# directory is there afterwards, on every host (#719): true for one it made
# and for one that already existed, false for one it could not make. The
# hosts' _xt_mkdir return different things (1 for done on arm64, 0 on x86-64
# Linux and win64), and reading the call's result as the answer inverted it
# on the latter.
#
# This machine's native target, and win64 under Wine when it is installed.
# Both drivers.
#
#   bash tests/driver/files-create-directory.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
fail=0; pass=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
D="$W/made"
cat > "$W/mk.xc" <<XCEOF
#import "Foundation.xc"
#import "Files.xc"
i32 main(void)
    {
    String* p = String.withCString("$D/inner");
    Stdio.printf("%d", Files.createDirectory(String.withCString("$D")) ? 1 : 0);
    Stdio.printf(" %d", Files.createDirectory(p) ? 1 : 0);
    Stdio.printf(" %d", Files.createDirectory(p) ? 1 : 0);
    Stdio.printf(" %d\n", Files.createDirectory(String.withCString("$W/no/such/parent")) ? 1 : 0);
    return 0;
    }
XCEOF
check() { # <label> <output>
    if [ "$2" = "1 1 1 0" ] && [ -d "$D/inner" ]; then pass=$((pass + 1)); else echo "FAIL $1: '$2'"; fail=1; fi
    rm -rf "$D"
}
for c in "$REF" "$XC"; do
    n=$(basename "$c")
    "$c" -q -H . -o "$W/mk" "$W/mk.xc" > "$W/err" 2>&1 || { echo "FAIL $n build: $(head -1 "$W/err")"; fail=1; continue; }
    check "$n native" "$("$W/mk")"
    if command -v wine > /dev/null && [ "$PLAT" = linux ]; then
        "$c" -q -H . -A win64 -o "$W/mk.exe" "$W/mk.xc" > "$W/err" 2>&1 || { echo "FAIL $n win64 build: $(head -1 "$W/err")"; fail=1; continue; }
        check "$n win64" "$(WINEPREFIX=${WINEPREFIX:-$HOME/.wine-gates} WINEDLLOVERRIDES=winedbg.exe=d timeout 60 wine "$W/mk.exe" 2>/dev/null | tr -d '\r')"
    fi
done
echo "files-create-directory: $pass passed$([ $fail = 0 ] || echo ', FAILURES')"
exit $fail
