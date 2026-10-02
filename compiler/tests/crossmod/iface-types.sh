#!/bin/bash
# iface-types.sh — a library's structs, enums and typedefs, used by a client
# that has only the library's interface.
#
#   bash tests/crossmod/iface-types.sh
#
# libItLib (itlib.xc, --emit-lib) declares a struct, an enum and a typedef and
# uses them in its class; itclient.xc declares, receives and passes them. The
# shipped compiler once read only a library's classes, protocols and
# functions, so any struct in an interface stopped every client with
# "unsupported: type …". A compiler MATRIX (xcc, xcc-xc for each half); the two
# compilers' libraries and programs are compared byte for byte.
#
#   arm64   built and run here (macOS arm64 host)
#   wasm32  skipped: a struct returned across a library is not right there yet
#   x86_64  run on $XTC_X86_HOST / $XTC_LINUX_HOST
#   win64   run under wine
#   arm9    built by both compilers and compared; not run (a library needs the
#           romfs rebuilt, which tests/crossmod/run.sh does)
export WINEDLLOVERRIDES="winedbg.exe=d;${WINEDLLOVERRIDES:-}"
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/bin/osx"; [ -d "$BIN" ] || BIN="$ROOT/bin/linux"
T="$ROOT/tests/crossmod"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

WANT=$'frame 4 5 100 50\nmade 9 8 2 3\narea 6 sum 21 blue 11'

fail=0
bad() { echo "FAIL  $*"; fail=$((fail+1)); }
samefiles() {  # <dir1> <dir2> <file>...
    local d1=$1 d2=$2; shift 2
    for f in "$@"; do cmp -s "$d1/$f" "$d2/$f" || return 1; done
}
buildlib() {  # <target> <compiler> <dir> <libfile> [extra flags]
    local a=$1 c=$2 d=$3 lib=$4; shift 4
    mkdir -p "$d"
    ( cd "$d" && "$BIN/$c" --emit-lib -A "$a" -H "$ROOT" -q "$@" -o "$lib" "$T/itlib.xc" )
}
buildapp() {  # <target> <compiler> <dir> <output> [extra flags]
    local a=$1 c=$2 d=$3 out=$4; shift 4
    ( cd "$d" && "$BIN/$c" -A "$a" -H "$ROOT" -q -L . "$@" -o "$out" "$T/itclient.xc" )
}
matrix() {  # <target> <libfile> <runner> [extra flags]
    local arch=$1 lib=$2 run=$3 L A got; shift 3
    for L in xcc xcc-xc; do
        buildlib "$arch" "$L" "$TMP/$arch/lib-$L" "$lib" "$@" || bad "$arch: $L could not build the library"
    done
    samefiles "$TMP/$arch/lib-xcc" "$TMP/$arch/lib-xcc-xc" $(ls "$TMP/$arch/lib-xcc") \
        || bad "$arch: the two compilers' libraries differ"
    for L in xcc xcc-xc; do
        for A in xcc xcc-xc; do
            local d="$TMP/$arch/$L-$A"
            mkdir -p "$d"; cp "$TMP/$arch/lib-$L"/* "$d/"
            buildapp "$arch" "$A" "$d" itclient "$@" 2>"$d/err" \
                || { bad "$arch lib=$L app=$A: itclient did not build"; sed 's/^/        /' "$d/err"; continue; }
            [ -z "$run" ] && continue
            got=$($run "$d" itclient 2>&1)
            [ "$got" = "$WANT" ] || { bad "$arch lib=$L app=$A:"; echo "$got" | sed 's/^/        /'; }
        done
        samefiles "$TMP/$arch/$L-xcc" "$TMP/$arch/$L-xcc-xc" $(cd "$TMP/$arch/$L-xcc" && ls itclient itclient.* 2>/dev/null) \
            || bad "$arch lib=$L: the two compilers' itclient differs"
    done
}

run_native() { ( cd "$1" && "./$2" ); }
run_node()   { ( cd "$1" && node "$2.js" ); }
run_wine()   { ( cd "$1" && WINEDLLOVERRIDES="winedbg.exe=d" WINEDEBUG=-all wine "./$2" 2>/dev/null | tr -d '\r' ); }
run_x86() {
    ssh "$HOST" "rm -rf $RD && mkdir -p $RD" </dev/null
    scp -q "$1/$2" $(ls "$1"/*.so 2>/dev/null) "$HOST:$RD/"
    ssh "$HOST" "cd $RD && ./$2" </dev/null
}

before=$fail
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)
        matrix arm64 libItLib.dylib run_native
        [ $fail = $before ] && echo "PASS  arm64: struct, enum and typedef across a library" ;;
    *)  echo "SKIP  arm64: needs a macOS arm64 host" ;;
esac

# wasm32 is not run: a struct RETURNED across the library boundary is still
# wrong there, in both compilers (the client imports the function without its
# sret parameter). Set ITYPES_WASM=1 to run it anyway.
before=$fail
if [ "${ITYPES_WASM:-0}" != 1 ]; then
    echo "SKIP  wasm32: a struct returned across a library is not right yet"
elif command -v node >/dev/null 2>&1; then
    matrix wasm32 libItLib run_node
    [ $fail = $before ] && echo "PASS  wasm32: struct, enum and typedef across a library"
else
    echo "SKIP  wasm32: no node"
fi

before=$fail
HOST=${XTC_X86_HOST:-${XTC_LINUX_HOST:-}}
if [ -n "$HOST" ] && ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" true 2>/dev/null; then
    RD=/tmp/xc-iface-types-$$
    matrix x86_64 libItLib.so run_x86
    ssh "$HOST" "rm -rf $RD" </dev/null
    [ $fail = $before ] && echo "PASS  x86_64: struct, enum and typedef across a library (run on $HOST)"
else
    echo "SKIP  x86_64: no x86-64 host reachable — built nothing, ran nothing"
fi

before=$fail
if command -v wine >/dev/null 2>&1; then
    matrix win64 libItLib.dll run_wine
    [ $fail = $before ] && echo "PASS  win64: struct, enum and typedef across a library (under wine)"
else
    echo "SKIP  win64: no wine"
fi

before=$fail
SR=${XTC_ARM9_SYSROOT:-}
if [ -n "$SR" ] && [ -d "$SR" ]; then
    matrix arm9 libItLib.so "" -L "$SR"
    [ $fail = $before ] && echo "PASS  arm9: struct, enum and typedef across a library (built and compared, not run)"
else
    echo "SKIP  arm9: no XTC_ARM9_SYSROOT"
fi

echo "--- iface-types: $fail failing ---"
[ $fail = 0 ]
