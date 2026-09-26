#!/bin/bash
# protocols.sh — dispatch through the prelude protocols across a library
# boundary, on every target this host can run a library for.
#
#   bash tests/crossmod/protocols.sh
#
# A library that calls `h.hash()` on a `Hashable*`, `a.equals(b)` on a
# `Comparable*` or an `Object*`, or `s.byteLength()` on a `String*` is handed
# objects its client made. Hashable, Comparable, Object and String belong to
# neither module, so the interface carries no slot numbers for them. A protocol
# call goes through the conformance itable, keyed by the protocol's id and the
# method's declaration index, which both modules derive alike; a client program
# adopts the library's slots for the prelude classes (`ambientSlots`).
#
# Two clients: protoclient.xc (its own class answering to the protocols, and the
# library's Box called through them) and protosub.xc (a subclass of Box). Each
# has an override root of its own, which moves its numbering off the library's.
# Before the fix the library read its own slot numbers out of the client's
# tables: wrong answers, a null call on wasm32, a segfault on arm64.
#
# Run as a lib x app compiler MATRIX (xcc, xcc-xc), and the two compilers'
# libraries and apps are compared byte for byte.
#
#   arm64   built and run here (macOS arm64 host)
#   wasm32  run under node
#   x86_64  run on $XTC_X86_HOST / $XTC_LINUX_HOST. Only protoclient: a client
#           subclass of a library class does not link on x86_64 yet, and the
#           shipped compiler's in-house link of a dynamic client fails there;
#           its app is checked as assembly, byte for byte against xcc's.
#   arm9    tests/crossmod/run.sh (needs the loader tree and qemu)
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/bin/osx"; [ -d "$BIN" ] || BIN="$ROOT/bin/linux"
T="$ROOT/tests/crossmod"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

WANT_CLIENT=$'own=2\nlib-hash=77\nlib-cmp=1\nlib-obj=1\nlib-bound=77\nlib-len=5\napp-hash=22\napp-cmp=0\napp-obj=0'
WANT_SUB=$'own=2\nlib-hash=99\nlib-cmp=1\nlib-obj=1\nlib-bound=99\napp-hash=99\napp-box=99'

fail=0
bad() { echo "FAIL  $*"; fail=$((fail+1)); }

# buildlib <target> <compiler> <dir> <libfile> — the library, in its own directory
# (its file name is recorded in it).
buildlib() {
    mkdir -p "$3"
    ( cd "$3" && "$BIN/$2" --emit-lib -A "$1" -H "$ROOT" -q -o "$4" "$T/protolib.xc" )
}
buildapp() {  # <target> <compiler> <dir> <client> <output> [extra flags]
    local a=$1 c=$2 d=$3 src=$4 out=$5; shift 5
    ( cd "$d" && "$BIN/$c" -A "$a" -H "$ROOT" -q -L . "$@" -o "$out" "$T/$src.xc" )
}
samefiles() {  # <dir1> <dir2> <file>...
    local d1=$1 d2=$2; shift 2
    for f in "$@"; do cmp -s "$d1/$f" "$d2/$f" || return 1; done
}

matrix() {  # <target> <libfile> <runner> <clients...>
    local arch=$1 lib=$2 run=$3; shift 3
    local L A c got want
    for L in xcc xcc-xc; do
        buildlib "$arch" "$L" "$TMP/$arch/lib-$L" "$lib" || { bad "$arch: $L could not build the library"; continue; }
    done
    samefiles "$TMP/$arch/lib-xcc" "$TMP/$arch/lib-xcc-xc" $(ls "$TMP/$arch/lib-xcc") \
        || bad "$arch: the two compilers' libraries differ"
    for L in xcc xcc-xc; do
        for A in xcc xcc-xc; do
            local d="$TMP/$arch/$L-$A"
            mkdir -p "$d"; cp "$TMP/$arch/lib-$L"/* "$d/"
            for c in "$@"; do
                buildapp "$arch" "$A" "$d" "$c" "$c" 2>"$d/$c.err" || { bad "$arch lib=$L app=$A: $c did not build"; continue; }
                got=$($run "$d" "$c" 2>&1)
                [ "$c" = protosub ] && want=$WANT_SUB || want=$WANT_CLIENT
                if [ "$got" != "$want" ]; then
                    bad "$arch lib=$L app=$A $c:"; echo "$got" | sed 's/^/        /'
                fi
            done
        done
        for c in "$@"; do
            ls "$TMP/$arch/$L-xcc/$c"* >/dev/null 2>&1 || continue
            samefiles "$TMP/$arch/$L-xcc" "$TMP/$arch/$L-xcc-xc" $(cd "$TMP/$arch/$L-xcc" && ls "$c" "$c".* 2>/dev/null | grep -v '\.err$') \
                || bad "$arch lib=$L: the two compilers' $c differs"
        done
    done
}

run_native() { ( cd "$1" && "./$2" ); }
run_node()   { ( cd "$1" && node "$2.js" ); }

before=$fail
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)
        matrix arm64 libProtoLib.dylib run_native protoclient protosub
        [ $fail = $before ] && echo "PASS  arm64: prelude protocols, Object and String across a .dylib" ;;
    *)  echo "SKIP  arm64: needs a macOS arm64 host" ;;
esac

before=$fail
if command -v node >/dev/null 2>&1; then
    matrix wasm32 libProtoLib run_node protoclient protosub
    [ $fail = $before ] && echo "PASS  wasm32: prelude protocols, Object and String across modules"
else
    echo "SKIP  wasm32: no node"
fi

before=$fail
HOST=${XTC_X86_HOST:-${XTC_LINUX_HOST:-}}
if [ -n "$HOST" ] && ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" true 2>/dev/null; then
    RD=/tmp/xc-protocols-$$
    for L in xcc xcc-xc; do
        d="$TMP/x86_64/$L"
        buildlib x86_64 "$L" "$d" libProtoLib.so || { bad "x86_64: $L could not build the library"; continue; }
        buildapp x86_64 xcc "$d" protoclient protoclient 2>"$d/err" || { bad "x86_64 lib=$L: protoclient did not build"; continue; }
        ssh "$HOST" "rm -rf $RD && mkdir -p $RD" </dev/null
        scp -q "$d/protoclient" "$d/libProtoLib.so" "$HOST:$RD/"
        got=$(ssh "$HOST" "cd $RD && ./protoclient" </dev/null 2>&1)
        [ "$got" = "$WANT_CLIENT" ] || { bad "x86_64 lib=$L:"; echo "$got" | sed 's/^/        /'; }
    done
    ssh "$HOST" "rm -rf $RD" </dev/null
    samefiles "$TMP/x86_64/xcc" "$TMP/x86_64/xcc-xc" libProtoLib.so \
        || bad "x86_64: the two compilers' libraries differ"
    d="$TMP/x86_64/xcc"
    buildapp x86_64 xcc "$d" protoclient xcc.s -S 2>/dev/null
    buildapp x86_64 xcc-xc "$d" protoclient xc.s -S 2>/dev/null
    cmp -s "$d/xcc.s" "$d/xc.s" || bad "x86_64: the two compilers' protoclient assembly differs"
    [ $fail = $before ] && echo "PASS  x86_64: prelude protocols, Object and String across a .so (run on $HOST)"
else
    echo "SKIP  x86_64: no x86-64 host reachable — built nothing, ran nothing"
fi

echo "--- protocols: $fail failing ---"
[ "$fail" = 0 ]
