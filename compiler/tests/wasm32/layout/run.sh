#!/bin/bash
# wasm32 memory layout: the shadow stack sits at 0x10000 below all static
# data, library data goes after the app's data, and the heap starts above the
# last library's data.
#
#   1. bigapp: 1.2 MB of the app's own static data plus a library with 400 KB
#      more (together far past 1 MiB), 4 MB of heap and a 2,000-frame call
#      chain. Every table must read back intact.
#   2. deep: unbounded recursion traps ("RuntimeError: unreachable") when the
#      shadow stack runs out, after a shallow call has left the data intact;
#      with --stack-size 65536 the shallow call traps already.
#   3. Both compilers emit the same WAT for the app, the library and a
#      --stack-size build.
#
#   bash tests/wasm32/layout/run.sh          (XCC= the compiler under test,
#                                             default bin/<plat>/xcc-xc)
set -u
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
cd "$(dirname "$0")" || exit 1
HERE=$(pwd)
ROOT=$(cd ../../.. && pwd)
XCC=${XCC:-$ROOT/bin/$XC_PLAT/xcc-xc}
case "$XCC" in /*) ;; *) XCC=$ROOT/$XCC;; esac
REF=${REF:-$ROOT/bin/$XC_PLAT/xcc}
command -v node >/dev/null || { echo "wasm32 layout: SKIP (no node)"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fails=0
fail() { echo "FAIL: $*"; fails=$((fails+1)); }

run_with() {   # run_with <compiler> <tag>
    local C=$1 T=$2 D="$W/$2"
    mkdir -p "$D"; cd "$D" || return
    "$C" -q -A wasm32 --emit-lib -H "$ROOT" -o libBigLib "$HERE/BigLib.xc" > build.log 2>&1 \
        || { fail "$T: the library did not build"; sed 's/^/    /' build.log | head -5; return; }
    "$C" -q -A wasm32 -L . -H "$ROOT" -o bigapp "$HERE/bigapp.xc" >> build.log 2>&1 \
        || { fail "$T: bigapp did not build"; sed 's/^/    /' build.log | head -5; return; }
    out=$(node bigapp.js 2>&1)
    [ "$out" = "blocks 16 depth 3 app damage 0 lib damage 0" ] \
        || fail "$T: bigapp printed: $(echo "$out" | head -3)"
    "$C" -q -A wasm32 -H "$ROOT" -o deep "$HERE/deep.xc" >> build.log 2>&1 \
        || { fail "$T: deep did not build"; return; }
    out=$(node deep.js 2>&1); rc=$?
    echo "$out" | grep -q '^shallow 101$' && echo "$out" | grep -q '^guard damage 0$' \
        && echo "$out" | grep -q 'RuntimeError: unreachable' && ! echo "$out" | grep -q '^deep ' && [ $rc != 0 ] \
        || fail "$T: deep did not trap cleanly (status $rc): $(echo "$out" | head -4)"
    "$C" -q -A wasm32 --stack-size 65536 -H "$ROOT" -o deep64 "$HERE/deep.xc" >> build.log 2>&1 \
        || { fail "$T: deep --stack-size 65536 did not build"; return; }
    out=$(node deep64.js 2>&1)
    echo "$out" | grep -q 'RuntimeError: unreachable' && ! echo "$out" | grep -q '^shallow' \
        || fail "$T: a 64 KiB stack did not trap on 100 4 KB frames: $(echo "$out" | head -3)"
}

run_with "$XCC" xcc-xc
[ -x "$REF" ] && [ "$REF" != "$XCC" ] && run_with "$REF" reference

# The two compilers' WAT, byte for byte.
if [ -x "$REF" ] && [ "$REF" != "$XCC" ]; then
    D="$W/wat"; mkdir -p "$D"; cd "$D" || exit 1
    cp "$W/xcc-xc/libBigLib.wasm" "$W/xcc-xc/libBigLib.json" . 2>/dev/null
    for C in "$XCC:x" "$REF:r"; do
        "${C%:*}" -q -A wasm32 --emit-lib -H "$ROOT" -o "lib.${C#*:}.wat" "$HERE/BigLib.xc" >/dev/null 2>&1
        "${C%:*}" -q -A wasm32 -L . -H "$ROOT" -o "app.${C#*:}.wat" "$HERE/bigapp.xc" >/dev/null 2>&1
        "${C%:*}" -q -A wasm32 -ss 65536 -H "$ROOT" -o "deep.${C#*:}.wat" "$HERE/deep.xc" >/dev/null 2>&1
    done
    for f in lib app deep; do
        [ -s "$f.x.wat" ] && cmp -s "$f.x.wat" "$f.r.wat" || fail "$f: the two compilers' WAT differs"
    done
fi

[ $fails = 0 ] && { echo "wasm32 layout: PASS"; exit 0; }
echo "wasm32 layout: $fails failed"; exit 1
