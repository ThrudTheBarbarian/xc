#!/bin/bash
# static-call.sh — a client's static call into a class it sees only through a
# library, on every target this host can run a library for.
#
#   bash tests/crossmod/static-call.sh
#
# libSCLib imports Number; its client (scclient.xc) never imports Number.xc and
# calls `Number.with(...)`. The call runs Number's static-init guard inside the
# library, with the library's flag still clear: the client's own guard sets the
# client's copy of the flag. On arm64 and x86_64 the guard hoisted to the entry
# of `Number.with` used an address that was only computed after it, and the
# first call from a client wrote through a stale register (a segfault).
#
# Run as a lib x app compiler MATRIX (xcc, xcc-xc), and the two compilers'
# libraries and apps are compared byte for byte.
#
#   arm64   built and run here (macOS arm64 host)
#   wasm32  run under node
#   x86_64  run on $XTC_X86_HOST / $XTC_LINUX_HOST (app built by xcc; the
#           xcc-xc app is compared as assembly, as in protocols.sh)
#   arm9    built by both compilers and compared byte for byte (not run; the
#           port's client used to carry its own copy of every imported class's
#           vtable)
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/bin/osx"; [ -d "$BIN" ] || BIN="$ROOT/bin/linux"
T="$ROOT/tests/crossmod"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

WANT=$'start\nbig=5000000000\nsmall=-7\nd=5\nlib=hello'

fail=0
bad() { echo "FAIL  $*"; fail=$((fail+1)); }

buildlib() {  # <target> <compiler> <dir> <libfile> [extra flags]
    local a=$1 c=$2 d=$3 lib=$4; shift 4
    mkdir -p "$d"
    ( cd "$d" && "$BIN/$c" --emit-lib -A "$a" -H "$ROOT" -q "$@" -o "$lib" "$T/sclib.xc" )
}
buildapp() {  # <target> <compiler> <dir> <output> [extra flags]
    local a=$1 c=$2 d=$3 out=$4; shift 4
    ( cd "$d" && "$BIN/$c" -A "$a" -H "$ROOT" -q -L . "$@" -o "$out" "$T/scclient.xc" )
}
samefiles() {  # <dir1> <dir2> <file>...
    local d1=$1 d2=$2; shift 2
    for f in "$@"; do cmp -s "$d1/$f" "$d2/$f" || return 1; done
}

matrix() {  # <target> <libfile> <runner>
    local arch=$1 lib=$2 run=$3 L A got
    for L in xcc xcc-xc; do
        buildlib "$arch" "$L" "$TMP/$arch/lib-$L" "$lib" || bad "$arch: $L could not build the library"
    done
    samefiles "$TMP/$arch/lib-xcc" "$TMP/$arch/lib-xcc-xc" $(ls "$TMP/$arch/lib-xcc") \
        || bad "$arch: the two compilers' libraries differ"
    for L in xcc xcc-xc; do
        for A in xcc xcc-xc; do
            local d="$TMP/$arch/$L-$A"
            mkdir -p "$d"; cp "$TMP/$arch/lib-$L"/* "$d/"
            buildapp "$arch" "$A" "$d" scclient 2>"$d/err" || { bad "$arch lib=$L app=$A: scclient did not build"; continue; }
            got=$($run "$d" scclient 2>&1)
            [ "$got" = "$WANT" ] || { bad "$arch lib=$L app=$A:"; echo "$got" | sed 's/^/        /'; }
        done
        samefiles "$TMP/$arch/$L-xcc" "$TMP/$arch/$L-xcc-xc" $(cd "$TMP/$arch/$L-xcc" && ls scclient scclient.* 2>/dev/null) \
            || bad "$arch lib=$L: the two compilers' scclient differs"
    done
}

run_native() { ( cd "$1" && "./$2" ); }
run_node()   { ( cd "$1" && node "$2.js" ); }

before=$fail
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)
        matrix arm64 libSCLib.dylib run_native
        [ $fail = $before ] && echo "PASS  arm64: static calls into a library's imported class" ;;
    *)  echo "SKIP  arm64: needs a macOS arm64 host" ;;
esac

before=$fail
if command -v node >/dev/null 2>&1; then
    matrix wasm32 libSCLib run_node
    [ $fail = $before ] && echo "PASS  wasm32: static calls into a library's imported class"
else
    echo "SKIP  wasm32: no node"
fi

before=$fail
HOST=${XTC_X86_HOST:-${XTC_LINUX_HOST:-}}
if [ -n "$HOST" ] && ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" true 2>/dev/null; then
    RD=/tmp/xc-static-call-$$
    for L in xcc xcc-xc; do
        d="$TMP/x86_64/$L"
        buildlib x86_64 "$L" "$d" libSCLib.so || { bad "x86_64: $L could not build the library"; continue; }
        buildapp x86_64 xcc "$d" scclient 2>"$d/err" || { bad "x86_64 lib=$L: scclient did not build"; continue; }
        ssh "$HOST" "rm -rf $RD && mkdir -p $RD" </dev/null
        scp -q "$d/scclient" "$d/libSCLib.so" "$HOST:$RD/"
        got=$(ssh "$HOST" "cd $RD && ./scclient" </dev/null 2>&1)
        [ "$got" = "$WANT" ] || { bad "x86_64 lib=$L:"; echo "$got" | sed 's/^/        /'; }
    done
    ssh "$HOST" "rm -rf $RD" </dev/null
    samefiles "$TMP/x86_64/xcc" "$TMP/x86_64/xcc-xc" libSCLib.so \
        || bad "x86_64: the two compilers' libraries differ"
    d="$TMP/x86_64/xcc"
    buildapp x86_64 xcc "$d" xcc.s -S 2>/dev/null
    buildapp x86_64 xcc-xc "$d" xc.s -S 2>/dev/null
    cmp -s "$d/xcc.s" "$d/xc.s" || bad "x86_64: the two compilers' scclient assembly differs"
    [ $fail = $before ] && echo "PASS  x86_64: static calls into a library's imported class (run on $HOST)"
else
    echo "SKIP  x86_64: no x86-64 host reachable — built nothing, ran nothing"
fi

before=$fail
SR=${XTC_ARM9_SYSROOT:-}
if [ -n "$SR" ] && [ -d "$SR" ]; then
    for L in xcc xcc-xc; do
        d="$TMP/arm9/$L"
        buildlib arm9 "$L" "$d" libSCLib.so -L "$SR" || { bad "arm9: $L could not build the library"; continue; }
        buildapp arm9 "$L" "$d" scclient -L "$SR" || bad "arm9: $L could not build scclient"
    done
    samefiles "$TMP/arm9/xcc" "$TMP/arm9/xcc-xc" $(ls "$TMP/arm9/xcc" 2>/dev/null) \
        || bad "arm9: the two compilers' library or client differs"
    [ $fail = $before ] && echo "PASS  arm9: library and client built and compared (not run)"
else
    echo "SKIP  arm9: no \$XTC_ARM9_SYSROOT"
fi

echo "--- static-call: $fail failing ---"
[ "$fail" = 0 ]
