#!/bin/sh
# Spike A proof — foreign C calls back into xtc with a void* context word.
#
# A genuinely foreign C shim (run_callback_n) invokes an xtc free function N
# times, handing it a context pointer; the callback casts the context back to an
# xtc object and dispatches a method. Proves the callback-with-context mechanism
# the GUI framework's event model depends on (private:docs/Design/cross-platform-gui.md
# §4.1 / §6 Spike A). Runs the SAME proof.xc on two dissimilar ABIs.
#
# Usage:  tests/interop/callback-context/run.sh            # arm64 (native) + win64 (Wine) if available
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
xtc="$root/bin/osx/xcc"
exp="$(cat "$here/expected.out")"
fail=0

echo "== arm64 (AAPCS, native host) =="
clang -O2 -shared -install_name "$work/libproofshim.dylib" \
      -o "$work/libproofshim.dylib" "$here/proofshim.c"
"$xtc" -H "$root" -A arm64 -L "$work" -o "$work/proof" "$here/proof.xc" >/dev/null 2>&1
got=$("$work/proof")
[ "$got" = "$exp" ] && echo "  PASS ($got)" || { echo "  FAIL: got '$got' want '$exp'"; fail=1; }

if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1 && command -v wine >/dev/null 2>&1; then
    echo "== win64 (Win64 ABI, under Wine) =="
    x86_64-w64-mingw32-gcc -O2 -shared -o "$work/proofshim.dll" "$here/proofshim.c" \
        -Wl,--out-implib,"$work/libproofshim.dll.a"
    "$xtc" -H "$root" -A win64 -L "$work" -o "$work/proof.exe" "$here/proof.xc" >/dev/null 2>&1
    # proof.exe and proofshim.dll are already co-located in $work.
    got=$(cd "$work" && WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;" wine proof.exe 2>/dev/null)
    [ "$got" = "$exp" ] && echo "  PASS ($got)" || { echo "  FAIL: got '$got' want '$exp'"; fail=1; }
else
    echo "== win64: skipped (mingw/wine not present) =="
fi

exit $fail
