#!/bin/bash
# classnames.sh — runtime class names across a module boundary, on every
# target this host can run.
#
#   bash tests/crossmod/classnames.sh
#
# `o.className()` must name an instance whose class another module built, and
# `Object.newInstanceOfClass(name)` must find a class that another module
# defines. Two shapes:
#
#   library  libCnLib (cnlib.xc, --emit-lib) and its client cnclient.xc. The
#            library hands back a Wedge the client only ever holds as a Shape;
#            the client makes the library's classes by name; the library's own
#            lookup finds its own classes and not the client's.
#   object   cnobj.xc and cnobjmain.xc, each compiled with -c and linked
#            together; the program imports cnobj's interface.
#
# Each is a compiler MATRIX (xcc, xcc-xc for each half), and the two
# compilers' libraries, objects and programs are compared byte for byte.
#
#   arm64   both shapes, built and run here (macOS arm64 host)
#   wasm32  the library, run under node (wasm32 has no -c)
#   x86_64  both, run on $XTC_X86_HOST / $XTC_LINUX_HOST. A library client is
#           compared as assembly: the two drivers' dynamic links export
#           different symbol sets.
#   win64   both, run under wine; libraries, objects and programs compared
#           byte for byte
#   arm9    both shapes built by both compilers and compared, not run. A
#           library needs the romfs rebuilt to run (tests/crossmod/run.sh does
#           that), and linking arm9 objects fails at load on an undefined
#           `_xtc_new_pointer` for any program, with or without class names.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/bin/osx"; [ -d "$BIN" ] || BIN="$ROOT/bin/linux"
T="$ROOT/tests/crossmod"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

WANT_LIB=$'lib wedge: Wedge\nLocal: Local\nShape: Shape\nSquare: Square\nWedge: Wedge\nString: String\nNothing: null\nsquare sides=4\nlib lookup: Wedge\nlib lookup of a client class: null'
WANT_OBJ=$'obj marker: Marker\nLocal: Local\nToken: Token\nMarker: Marker\nNothing: null\nmarker tag=42'

fail=0
bad() { echo "FAIL  $*"; fail=$((fail+1)); }
samefiles() {  # <dir1> <dir2> <file>...
    local d1=$1 d2=$2; shift 2
    for f in "$@"; do cmp -s "$d1/$f" "$d2/$f" || return 1; done
}

# ── the library shape ───────────────────────────────────────────────────────
buildlib() {  # <target> <compiler> <dir> <libfile> [extra flags]
    local a=$1 c=$2 d=$3 lib=$4; shift 4
    mkdir -p "$d"
    ( cd "$d" && "$BIN/$c" --emit-lib -A "$a" -H "$ROOT" -q "$@" -o "$lib" "$T/cnlib.xc" )
}
buildapp() {  # <target> <compiler> <dir> <output> [extra flags]
    local a=$1 c=$2 d=$3 out=$4; shift 4
    ( cd "$d" && "$BIN/$c" -A "$a" -H "$ROOT" -q -L . "$@" -o "$out" "$T/cnclient.xc" )
}
libmatrix() {  # <target> <libfile> <runner>
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
            buildapp "$arch" "$A" "$d" cnclient 2>"$d/err" || { bad "$arch lib=$L app=$A: cnclient did not build"; continue; }
            got=$($run "$d" cnclient 2>&1)
            [ "$got" = "$WANT_LIB" ] || { bad "$arch lib=$L app=$A:"; echo "$got" | sed 's/^/        /'; }
        done
        if [ "${APPCMP:-bin}" = asm ]; then
            buildapp "$arch" xcc "$TMP/$arch/$L-xcc" xcc.s -S 2>/dev/null
            buildapp "$arch" xcc-xc "$TMP/$arch/$L-xcc" xc.s -S 2>/dev/null
            cmp -s "$TMP/$arch/$L-xcc/xcc.s" "$TMP/$arch/$L-xcc/xc.s" \
                || bad "$arch lib=$L: the two compilers' cnclient assembly differs"
        else
            samefiles "$TMP/$arch/$L-xcc" "$TMP/$arch/$L-xcc-xc" $(cd "$TMP/$arch/$L-xcc" && ls cnclient cnclient.* 2>/dev/null) \
                || bad "$arch lib=$L: the two compilers' cnclient differs"
        fi
    done
}

# ── the object shape ────────────────────────────────────────────────────────
# objmatrix <target> <program> <runner> [extra flags]: cnobj.o from each
# compiler, cnobjmain.o from each, every pairing linked by the compiler that
# built the main object and run.
objmatrix() {
    local arch=$1 prog=$2 run=$3 O M got; shift 3
    for O in xcc xcc-xc; do
        local d="$TMP/$arch/obj-$O"
        mkdir -p "$d"
        ( cd "$d" && "$BIN/$O" -c -A "$arch" -H "$ROOT" -q "$@" -o cnobj.o "$T/cnobj.xc" ) \
            || bad "$arch: $O could not compile cnobj.o"
    done
    samefiles "$TMP/$arch/obj-xcc" "$TMP/$arch/obj-xcc-xc" cnobj.o cnobj.xtc.iface \
        || bad "$arch: the two compilers' cnobj.o or its interface differ"
    for O in xcc xcc-xc; do
        for M in xcc xcc-xc; do
            local d="$TMP/$arch/objs-$O-$M"
            mkdir -p "$d"; cp "$TMP/$arch/obj-$O"/* "$d/"
            ( cd "$d" && "$BIN/$M" -c -A "$arch" -H "$ROOT" -q -L . "$@" -o cnobjmain.o "$T/cnobjmain.xc" \
                && "$BIN/$M" -A "$arch" -H "$ROOT" -q "$@" -o "$prog" cnobjmain.o cnobj.o ) 2>"$d/err" \
                || { bad "$arch obj=$O main=$M: did not build"; sed 's/^/        /' "$d/err"; continue; }
            got=$($run "$d" "$prog" 2>&1)
            [ "$got" = "$WANT_OBJ" ] || { bad "$arch obj=$O main=$M:"; echo "$got" | sed 's/^/        /'; }
        done
        samefiles "$TMP/$arch/objs-$O-xcc" "$TMP/$arch/objs-$O-xcc-xc" cnobjmain.o "$prog" \
            || bad "$arch obj=$O: the two compilers' cnobjmain.o or program differ"
    done
}

run_native() { ( cd "$1" && "./$2" ); }
run_node()   { ( cd "$1" && node "$2.js" ); }
# run_wine: the crash dialog off, so a program that faults fails the test
# rather than opening a window.
run_wine()   { ( cd "$1" && WINEDLLOVERRIDES="winedbg.exe=d" WINEDEBUG=-all wine "./$2" 2>/dev/null | tr -d '\r' ); }
# run_x86 <dir> <prog> — the program and any libraries beside it, run on $HOST.
run_x86() {
    ssh "$HOST" "rm -rf $RD && mkdir -p $RD" </dev/null
    scp -q "$1/$2" $(ls "$1"/*.so 2>/dev/null) "$HOST:$RD/"
    ssh "$HOST" "cd $RD && ./$2" </dev/null
}

before=$fail
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)
        libmatrix arm64 libCnLib.dylib run_native
        objmatrix arm64 cnobjmain run_native
        [ $fail = $before ] && echo "PASS  arm64: class names across a library and an object" ;;
    *)  echo "SKIP  arm64: needs a macOS arm64 host" ;;
esac

before=$fail
if command -v node >/dev/null 2>&1; then
    libmatrix wasm32 libCnLib run_node
    [ $fail = $before ] && echo "PASS  wasm32: class names across a library"
else
    echo "SKIP  wasm32: no node"
fi

before=$fail
HOST=${XTC_X86_HOST:-${XTC_LINUX_HOST:-}}
if [ -n "$HOST" ] && ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" true 2>/dev/null; then
    RD=/tmp/xc-classnames-$$
    libmatrix x86_64 libCnLib.so run_x86
    objmatrix x86_64 cnobjmain run_x86
    ssh "$HOST" "rm -rf $RD" </dev/null
    [ $fail = $before ] && echo "PASS  x86_64: class names across a library and an object (run on $HOST)"
else
    echo "SKIP  x86_64: no x86-64 host reachable — built nothing, ran nothing"
fi

before=$fail
if command -v wine >/dev/null 2>&1; then
    libmatrix win64 libCnLib.dll run_wine
    objmatrix win64 cnobjmain.exe run_wine
    [ $fail = $before ] && echo "PASS  win64: class names across a library and an object (under wine)"
else
    echo "SKIP  win64: no wine"
fi

before=$fail
SR=${XTC_ARM9_SYSROOT:-}
if [ -n "$SR" ] && [ -d "$SR" ]; then
    for L in xcc xcc-xc; do
        d="$TMP/arm9/obj-$L"
        mkdir -p "$d"
        ( cd "$d" && "$BIN/$L" -c -A arm9 -H "$ROOT" -q -L "$SR" -o cnobj.o "$T/cnobj.xc" \
            && "$BIN/$L" -c -A arm9 -H "$ROOT" -q -L "$SR" -L . -o cnobjmain.o "$T/cnobjmain.xc" ) \
            || bad "arm9: $L could not compile the objects"
    done
    # cnobj's IR and interface sidecars, not the objects: the two drivers'
    # arm9 `-c` objects already differ in literal-pool placement (`.ltorg`)
    # for any source, and on arm9 a module that imports a `-c` interface
    # already lists the imported function's symbol at a different place in
    # its IR, with or without class names.
    samefiles "$TMP/arm9/obj-xcc" "$TMP/arm9/obj-xcc-xc" cnobj.xtc.ir cnobj.xtc.iface \
        || bad "arm9: the two compilers' object IR or interface differ"
    for L in xcc xcc-xc; do
        d="$TMP/arm9/lib-$L"
        buildlib arm9 "$L" "$d" libCnLib.so -L "$SR" || { bad "arm9: $L could not build the library"; continue; }
        buildapp arm9 "$L" "$d" cnclient -L "$SR" || bad "arm9: $L could not build cnclient"
    done
    samefiles "$TMP/arm9/lib-xcc" "$TMP/arm9/lib-xcc-xc" $(ls "$TMP/arm9/lib-xcc" 2>/dev/null) \
        || bad "arm9: the two compilers' library or client differs"
    [ $fail = $before ] && echo "PASS  arm9: objects, library and client built and compared (not run)"
else
    echo "SKIP  arm9: no \$XTC_ARM9_SYSROOT"
fi

echo "--- classnames: $fail failing ---"
[ "$fail" = 0 ]
