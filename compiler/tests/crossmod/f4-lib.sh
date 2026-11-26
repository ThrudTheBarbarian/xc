#!/bin/bash
# f4-lib.sh — a library with f4 in its interface (functions, an f4[]
# parameter, a struct with an f4 field and an f4 array field, a class holding
# an f4 array), used by a client that has only the interface. The types
# travel in the interface under their names (f4, f4[]), and each module
# converts through its own copy of the pack routines. A compiler MATRIX
# (xcc, xcc-xc for each half); the two compilers' libraries and programs are
# compared byte for byte.
#
#   bash tests/crossmod/f4-lib.sh
#
#   arm64   built and run here (macOS arm64 host)
#   wasm32  run under node
#   x86_64  run on $XTC_X86_HOST / $XTC_LINUX_HOST
#   win64   run under wine
#   arm9    built by both compilers and compared; not run (a library needs the
#           romfs rebuilt, which tests/crossmod/run.sh does)
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

WANT='t 2.000000 total 8.000000 n -0.500000 3.000000 9 c 3.000000 -6.000000 10.000000'

fail=0
bad() { echo "FAIL  $*"; fail=$((fail+1)); }
samefiles() {  # <dir1> <dir2> <file>...
    local d1=$1 d2=$2; shift 2
    for f in "$@"; do cmp -s "$d1/$f" "$d2/$f" || return 1; done
}
buildlib() {  # <target> <compiler> <dir> <libfile> [extra flags]
    local a=$1 c=$2 d=$3 lib=$4; shift 4
    mkdir -p "$d"
    ( cd "$d" && "$BIN/$c" --emit-lib -A "$a" -H "$ROOT" -q "$@" -o "$lib" "$T/f4lib.xc" )
}
buildapp() {  # <target> <compiler> <dir> <output> [extra flags]
    local a=$1 c=$2 d=$3 out=$4; shift 4
    ( cd "$d" && "$BIN/$c" -A "$a" -H "$ROOT" -q -L . "$@" -o "$out" "$T/f4client.xc" )
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
            buildapp "$arch" "$A" "$d" f4client "$@" 2>"$d/err" \
                || { bad "$arch lib=$L app=$A: f4client did not build"; sed 's/^/        /' "$d/err"; continue; }
            [ -z "$run" ] && continue
            got=$($run "$d" f4client 2>&1)
            [ "$got" = "$WANT" ] || { bad "$arch lib=$L app=$A:"; echo "$got" | sed 's/^/        /'; }
        done
        samefiles "$TMP/$arch/$L-xcc" "$TMP/$arch/$L-xcc-xc" $(cd "$TMP/$arch/$L-xcc" && ls f4client f4client.* 2>/dev/null) \
            || bad "$arch lib=$L: the two compilers' f4client differs"
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
        matrix arm64 libF4Lib.dylib run_native
        [ $fail = $before ] && echo "PASS  arm64: f4 across a library" ;;
    *)  echo "SKIP  arm64: needs a macOS arm64 host" ;;
esac

before=$fail
if command -v node >/dev/null 2>&1; then
    matrix wasm32 libF4Lib run_node
    [ $fail = $before ] && echo "PASS  wasm32: f4 across a library"
else
    echo "SKIP  wasm32: no node"
fi

before=$fail
HOST=${XTC_X86_HOST:-${XTC_LINUX_HOST:-}}
if [ -n "$HOST" ] && ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" true 2>/dev/null; then
    RD=/tmp/xc-f4-lib-$$
    matrix x86_64 libF4Lib.so run_x86
    ssh "$HOST" "rm -rf $RD" </dev/null
    [ $fail = $before ] && echo "PASS  x86_64: f4 across a library (run on $HOST)"
else
    echo "SKIP  x86_64: no x86-64 host reachable — built nothing, ran nothing"
fi

before=$fail
if command -v wine >/dev/null 2>&1; then
    matrix win64 libF4Lib.dll run_wine
    [ $fail = $before ] && echo "PASS  win64: f4 across a library (under wine)"
else
    echo "SKIP  win64: no wine"
fi

before=$fail
SR=${XTC_ARM9_SYSROOT:-}
if [ -n "$SR" ] && [ -d "$SR" ]; then
    matrix arm9 libF4Lib.so "" -L "$SR"
    [ $fail = $before ] && echo "PASS  arm9: f4 across a library (built and compared, not run)"
else
    echo "SKIP  arm9: no XTC_ARM9_SYSROOT"
fi

echo "--- f4-lib: $fail failing ---"
[ $fail = 0 ]
