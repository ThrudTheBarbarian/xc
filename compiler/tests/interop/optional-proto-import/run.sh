#!/bin/sh
# Regression: an `optional` protocol method must round-trip through the
# `.xtc.iface`, or the conformance re-check on IMPORT demands a method a class
# may legally omit. The real-world trigger is any library that uses `Array`:
# `Object <Hashable, Comparable>` implements the required `equals` but omits the
# optional `compare`, and importing the library materializes that conformance.
#
# Before the fix (XTInterfaceSerializer/Importer round-tripping `optional`), the
# client below failed with "Class 'Object' claims conformance to protocol
# 'Comparable' but doesn't implement 'compare'". Runs on the reachable hosts.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
xtc="$root/bin/osx/xcc"
exp="$(cat "$here/expected.out")"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail=0
check() { [ "$1" = "$exp" ] && echo "  PASS" || { echo "  FAIL: got '$1' want '$exp'"; fail=1; }; }

echo "== arm64 (native) =="
"$xtc" -H "$root" -A arm64 --emit-lib -o "$work/liboptlib.dylib" "$here/optlib.xc" -q 2>/dev/null
"$xtc" -H "$root" -A arm64 -L "$work" -o "$work/optcli" "$here/optcli.xc" -q 2>/dev/null
check "$("$work/optcli")"

if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1 && command -v wine >/dev/null 2>&1; then
    echo "== win64 (Wine) =="
    "$xtc" -H "$root" -A win64 --emit-lib -o "$work/liboptlib.dll" "$here/optlib.xc" -q 2>/dev/null
    "$xtc" -H "$root" -A win64 -L "$work" -o "$work/optcli.exe" "$here/optcli.xc" -q 2>/dev/null
    check "$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" wine optcli.exe 2>/dev/null)"
fi

exit $fail
