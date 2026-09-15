#!/bin/sh
# Spike 0 (Xtg multi-host) — the shared-object mechanism the Xtg host-backend
# design rests on: a LIBRARY reaching an APP's override across the `.so`, plus
# the optional-protocol-method-via-bound-pointer + weak-zeroing, plus struct
# by-value both directions. GEM-free port of the A9 libtable/libdemo oracle so
# it runs natively on the desktop hosts (no XTOS loader).
# See Rocks/doc/XTG-MULTIPLATFORM.md §8, §10 (Spike 0).
#
# Builds the library with --emit-lib and a separate app that #imports it, then
# runs the SAME app source on each reachable host:
#   arm64  — native (this Mac)
#   win64  — under Wine
#   x86_64 — over ssh (XTC_X86_HOST, or XTC_LINUX_HOST)
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
xtc="$root/bin/osx/xcc"
exp="$(cat "$here/expected.out")"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail=0
check() { [ "$1" = "$exp" ] && echo "  PASS" || { echo "  FAIL"; printf '  want:\n%s\n  got:\n%s\n' "$exp" "$1"; fail=1; }; }

echo "== arm64 (native) =="
"$xtc" -H "$root" -A arm64 --emit-lib -o "$work/libxgspike_lib.dylib" "$here/xgspike_lib.xc" -q
"$xtc" -H "$root" -A arm64 -L "$work" -o "$work/app" "$here/xgspike_app.xc" -q
check "$("$work/app")"

if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1 && command -v wine >/dev/null 2>&1; then
    echo "== win64 (Wine) =="
    "$xtc" -H "$root" -A win64 --emit-lib -o "$work/libxgspike_lib.dll" "$here/xgspike_lib.xc" -q 2>/dev/null
    "$xtc" -H "$root" -A win64 -L "$work" -o "$work/app.exe" "$here/xgspike_app.xc" -q 2>/dev/null
    check "$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" wine app.exe 2>/dev/null)"
else
    echo "== win64: skipped (mingw/wine absent) =="
fi

HOST="${XTC_X86_HOST:-${XTC_LINUX_HOST:-}}"
if ssh -o ConnectTimeout=6 -o BatchMode=yes "$HOST" true 2>/dev/null; then
    echo "== x86_64 (ssh $HOST) =="
    "$xtc" -H "$root" -A x86_64 --emit-lib -o "$work/libxgspike_lib.so" "$here/xgspike_lib.xc" -q 2>/dev/null
    "$xtc" -H "$root" -A x86_64 -L "$work" -o "$work/app_x86" "$here/xgspike_app.xc" -q 2>/dev/null
    rd="/tmp/xtg-spike0-run.$$"
    ssh -o BatchMode=yes "$HOST" "mkdir -p $rd"
    scp -o BatchMode=yes -q "$work/libxgspike_lib.so" "$work/app_x86" "$HOST:$rd/"
    got=$(ssh -o BatchMode=yes "$HOST" "cd $rd && chmod +x app_x86 && LD_LIBRARY_PATH=. ./app_x86; rm -rf $rd")
    check "$got"
else
    echo "== x86_64: skipped ($HOST unreachable) =="
fi

exit $fail
