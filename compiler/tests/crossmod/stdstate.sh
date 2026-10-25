#!/bin/bash
# stdstate.sh — one standard-library singleton per process across a library
# boundary, and a library's #defines in its clients (2026-10-23), on every
# target this host can run.
#
#   bash tests/crossmod/stdstate.sh
#
# A library exports the state of the standard-library files it was built with
# (globals, class static data); a program importing it, built from the same
# sources, binds to that copy instead of keeping its own. Before, each image
# had its own RunLoop.main(): a program's posts never reached the library's
# loop, and OperationQueue.main(), NotificationCenter.shared() and Null.null()
# were two objects each. And a library's own #defines are in its interface,
# so a client has them (in #if too) as an #import of the source would give.
#
#   library  libSsLib (sslib.xc, --emit-lib) and its client ssclient.xc, a
#            compiler MATRIX (xcc, xcc-xc for each half); the two compilers'
#            libraries and the programs are compared byte for byte, and the
#            programs run.
#   mismatch a library built from a standard library that differs by one
#            comment: the client warns and keeps its own copy (arm64).
#
#   arm64   built and run here (macOS arm64 host)
#   x86_64  run on $XTC_X86_HOST / $XTC_LINUX_HOST
#   win64   run under wine
#   wasm32  run under node (no RunLoop: it needs threads)
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
export WINEDLLOVERRIDES="winedbg.exe=d;${WINEDLLOVERRIDES:-}"
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/bin/$XC_PLAT"; [ -d "$BIN" ] || BIN="$ROOT/bin/linux"
T="$ROOT/tests/crossmod"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ONE=$'one OperationQueue.main(): 1\none NotificationCenter.shared(): 1\none Null.null(): 1\nthe library\'s defines: 42 14'
WANT=$'library ran 1 of the program\'s posts, hits 1\none RunLoop.main(): 1\n'"$ONE"
WANT_WASM="$ONE"

fail=0
bad() { echo "FAIL  $*"; fail=$((fail+1)); }
samefiles() {  # <dir1> <dir2> <file>...
    local d1=$1 d2=$2; shift 2
    for f in "$@"; do cmp -s "$d1/$f" "$d2/$f" || return 1; done
}
buildlib() {  # <target> <compiler> <dir> <libfile> [root]
    local a=$1 c=$2 d=$3 lib=$4 r=${5:-$ROOT}
    mkdir -p "$d"
    ( cd "$d" && "$BIN/$c" --emit-lib -A "$a" -H "$r" -q -o "$lib" "$T/sslib.xc" )
}
buildapp() {  # <target> <compiler> <dir> <output>
    local a=$1 c=$2 d=$3 out=$4
    ( cd "$d" && "$BIN/$c" -A "$a" -H "$ROOT" -q -L . -o "$out" "$T/ssclient.xc" )
}
libmatrix() {  # <target> <libfile> <program> <runner> <want>
    local arch=$1 lib=$2 prog=$3 run=$4 want=$5 L A got
    for L in xcc xcc-xc; do
        buildlib "$arch" "$L" "$TMP/$arch/lib-$L" "$lib" || bad "$arch: $L could not build the library"
    done
    samefiles "$TMP/$arch/lib-xcc" "$TMP/$arch/lib-xcc-xc" $(ls "$TMP/$arch/lib-xcc") \
        || bad "$arch: the two compilers' libraries differ"
    for L in xcc xcc-xc; do
        for A in xcc xcc-xc; do
            local d="$TMP/$arch/$L-$A"
            mkdir -p "$d"; cp "$TMP/$arch/lib-$L"/* "$d/"
            buildapp "$arch" "$A" "$d" "$prog" 2>"$d/err" || { bad "$arch lib=$L app=$A: ssclient did not build"; sed 's/^/        /' "$d/err"; continue; }
            got=$($run "$d" "$prog" 2>&1)
            [ "$got" = "$want" ] || { bad "$arch lib=$L app=$A:"; echo "$got" | sed 's/^/        /'; }
        done
        # …and against one library, the two compilers' programs are the same
        # bytes (they differed by the order of the library's stdImports, and
        # so of a trampoline, until 2026-10-24).
        # (wasm32 writes <prog>.js, .wasm and .html, not <prog> itself.)
        samefiles "$TMP/$arch/$L-xcc" "$TMP/$arch/$L-xcc-xc" $(cd "$TMP/$arch/$L-xcc" && ls "$prog" "$prog".* 2>/dev/null) \
            || bad "$arch lib=$L: the two compilers' programs differ"
    done
}

run_native() { ( cd "$1" && "./$2" ); }
run_node()   { ( cd "$1" && node "${2%.js}.js" ); }
run_wine()   { ( cd "$1" && WINEDLLOVERRIDES="winedbg.exe=d" WINEDEBUG=-all wine "./$2" 2>/dev/null | tr -d '\r' ); }
run_x86() {
    ssh "$HOST" "rm -rf $RD && mkdir -p $RD" </dev/null
    scp -q "$1/$2" $(ls "$1"/*.so 2>/dev/null) "$HOST:$RD/"
    ssh "$HOST" "cd $RD && ./$2" </dev/null
}

before=$fail
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)
        libmatrix arm64 libSsLib.dylib ssclient run_native "$WANT"
        # A library from other standard-library sources: the client warns and
        # keeps its own copy, so the singletons are two again.
        mkdir -p "$TMP/other"
        cp -R "$ROOT/support" "$TMP/other/support"
        printf '\n// a different standard library\n' >> "$TMP/other/support/generic/lib/Null.xc"
        d="$TMP/arm64/mismatch"
        for L in xcc xcc-xc; do
            buildlib arm64 "$L" "$d-$L" libSsLib.dylib "$TMP/other" || { bad "arm64 mismatch: $L could not build the library"; continue; }
            buildapp arm64 "$L" "$d-$L" ssclient 2>"$d-$L/err" || { bad "arm64 mismatch: $L: ssclient did not build"; continue; }
            grep -q "was built from other standard-library sources" "$d-$L/err" \
                || bad "arm64 mismatch: $L did not warn"
            got=$(run_native "$d-$L" ssclient 2>&1)
            echo "$got" | grep -q 'one Null.null(): 0' \
                || { bad "arm64 mismatch: $L bound to the library's state anyway:"; echo "$got" | sed 's/^/        /'; }
        done
        # A chain: libSsChain imports libSsLib, and a program imports only
        # libSsChain. Its singletons must be libSsLib's (the second library
        # names the first as the owner of its state, and the program imports
        # that library too); it kept its own copy before (2026-10-24).
        WANT_CHAIN=$'one OperationQueue.main(): 1\none NotificationCenter.shared(): 1\none Null.null(): 1'
        for L in xcc xcc-xc; do
            d="$TMP/arm64/chain-$L"
            buildlib arm64 "$L" "$d" libSsLib.dylib || { bad "arm64 chain: $L could not build libSsLib"; continue; }
            ( cd "$d" && "$BIN/$L" --emit-lib -A arm64 -H "$ROOT" -q -L . -o libSsChain.dylib "$T/sschain.xc" ) 2>"$d/err1" \
                || { bad "arm64 chain: $L could not build libSsChain"; sed 's/^/        /' "$d/err1"; continue; }
            ( cd "$d" && "$BIN/$L" -A arm64 -H "$ROOT" -q -L . -o sschainclient "$T/sschainclient.xc" ) 2>"$d/err2" \
                || { bad "arm64 chain: $L: sschainclient did not build"; sed 's/^/        /' "$d/err2"; continue; }
            got=$(run_native "$d" sschainclient 2>&1)
            [ "$got" = "$WANT_CHAIN" ] || { bad "arm64 chain, $L:"; echo "$got" | sed 's/^/        /'; }
        done
        [ $fail = $before ] && echo "PASS  arm64: one stdlib singleton per process across a library" ;;
    *)  echo "SKIP  arm64: needs a macOS arm64 host" ;;
esac

before=$fail
HOST=${XTC_X86_HOST:-${XTC_LINUX_HOST:-}}
if [ -n "$HOST" ] && ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" true 2>/dev/null; then
    RD=/tmp/xc-stdstate-$$
    libmatrix x86_64 libSsLib.so ssclient run_x86 "$WANT"
    ssh "$HOST" "rm -rf $RD" </dev/null
    [ $fail = $before ] && echo "PASS  x86_64: one stdlib singleton per process across a library (run on $HOST)"
else
    echo "SKIP  x86_64: no x86-64 host reachable — built nothing, ran nothing"
fi

before=$fail
if command -v wine >/dev/null 2>&1; then
    libmatrix win64 libSsLib.dll ssclient.exe run_wine "$WANT"
    [ $fail = $before ] && echo "PASS  win64: one stdlib singleton per process across a library (under wine)"
else
    echo "SKIP  win64: no wine"
fi

before=$fail
if command -v node >/dev/null 2>&1; then
    libmatrix wasm32 libSsLib ssclient run_node "$WANT_WASM"
    [ $fail = $before ] && echo "PASS  wasm32: one stdlib singleton per process across a library"
else
    echo "SKIP  wasm32: no node"
fi

[ $fail = 0 ] && echo "stdstate: all passed" || echo "stdstate: $fail failed"
[ $fail = 0 ]
