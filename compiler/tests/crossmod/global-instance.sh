#!/bin/bash
# global-instance.sh — global instances across a library boundary and to C
# (#641), on every target this host can run.
#
#   bash tests/crossmod/global-instance.sh
#
#   library  libgilib (gilib.xc, --emit-lib) holds a global instance, set up
#            by the library's load-time constructor; its client giclient.xc
#            has one of its own, set up in main's prologue. The library's is
#            set up first, then the program's, then main runs. The client
#            reaches the library's instance through its functions and, as
#            `extern Tally gTally;`, by name. A compiler MATRIX (xcc, xcc-xc
#            for each half): the two compilers' libraries and programs are
#            compared byte for byte, and the programs run.
#   C        gicmain.xc and gic.c: C reads and writes a global instance
#            through its symbol, which is the address of its fields, and the
#            immortal count sits in the word before them.
#   leaks    tests/fixtures/global_instance.xc under leaks --atExit: a global
#            instance is static data, never a leak.
#   static   gistatic.xc linked -static for x86-64 with giextra.o (-c), whose
#            dead array precedes a global instance: the header is intact and
#            retains and releases of the instance leave its neighbour alone.
#            Both compilers' programs are compared byte for byte and run on
#            $XTC_X86_HOST / $XTC_LINUX_HOST.
#   order    giorder.xc linked with gioa.o and giob.o (-c, #649), each with
#            a global instance whose init prints a line: the objects'
#            instances are set up before main in link order, then the
#            program's, and a virtual call on gioa's instance reaches its
#            override. arm64,
#            x86-64 -static and dynamic, and win64; both compilers' objects
#            and programs are compared byte for byte.
#
#   arm64   built and run here (macOS arm64 host)
#   win64   the library matrix and the order links under wine
#   x86_64  the static and order links, run on $XTC_X86_HOST / $XTC_LINUX_HOST
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

WANT=$'library instance set up\nprogram instance set up\nmain\nbump 41 42 mark 7\nextern 43 same 1\nagain 44'
WANT_C=$'C sees 7\nxc sees 30 34\nsame address 1 count 40000000'

fail=0
bad() { echo "FAIL  $*"; fail=$((fail+1)); }

# matrix <target> <libext> <runner...>
matrix() {
    local a=$1 ext=$2; shift 2
    local lc ac d got
    for lc in xcc xcc-xc; do
        mkdir -p "$TMP/$a/lib-$lc"
        ( cd "$TMP/$a/lib-$lc" && "$BIN/$lc" -q -A "$a" -H "$ROOT" --emit-lib -o "libgilib.$ext" "$T/gilib.xc" ) \
            || { bad "$a: $lc could not build libgilib"; return; }
    done
    cmp -s "$TMP/$a/lib-xcc/libgilib.$ext" "$TMP/$a/lib-xcc-xc/libgilib.$ext" || bad "$a: the two compilers' libgilib differ"
    for lc in xcc xcc-xc; do
        for ac in xcc xcc-xc; do
            d="$TMP/$a/$lc-$ac"
            mkdir -p "$d"
            cp "$TMP/$a/lib-$lc"/* "$d/"
            ( cd "$d" && "$BIN/$ac" -q -A "$a" -H "$ROOT" -L . -o giclient "$T/giclient.xc" ) \
                || { bad "$a: $ac could not build giclient against $lc's library"; continue; }
            got=$(cd "$d" && "$@" ./giclient 2>/dev/null | tr -d '\r')
            [ "$got" = "$WANT" ] || { bad "$a: giclient ($ac, library by $lc)"; echo "$got" | head -6; }
        done
        cmp -s "$TMP/$a/$lc-xcc/giclient" "$TMP/$a/$lc-xcc-xc/giclient" || bad "$a: the two compilers' giclient differs"
    done
    [ $fail = 0 ] && echo "PASS  $a: a library's global instance, set up at load, used by name and through the library"
}

if [ "$(uname -s)" = Darwin ]; then
    matrix arm64 dylib env
    for c in xcc xcc-xc; do
        clang -c -O2 -o "$TMP/gic.o" "$T/gic.c" || { bad "C: clang"; break; }
        ( cd "$TMP" && "$BIN/$c" -q -H "$ROOT" -o "gic-$c" "$T/gicmain.xc" -Wl,gic.o ) || { bad "C: $c could not build gicmain"; continue; }
        got=$("$TMP/gic-$c")
        [ "$got" = "$WANT_C" ] && echo "PASS  arm64: C sees the global instance's fields ($c)" || { bad "C ($c)"; echo "$got"; }
    done
    "$BIN/xcc-xc" -q -H "$ROOT" -o "$TMP/gi" "$ROOT/tests/fixtures/global_instance.xc" || bad "leaks: build"
    if leaks --atExit -- "$TMP/gi" 2>&1 | grep -q " 0 leaks for 0 total leaked bytes"; then
        echo "PASS  arm64: global_instance leaks nothing"
    else
        bad "leaks: global_instance"
    fi
fi
WANT_S=$'header 58544f4e 40000000\nheld 400003e8\nreleased 40000000 next 99'
for c in xcc xcc-xc; do
    mkdir -p "$TMP/static-$c"
    ( cd "$TMP/static-$c" && "$BIN/$c" -q -A x86_64 -H "$ROOT" -c -o giextra.o "$T/giextra.xc" \
        && "$BIN/$c" -q -A x86_64 -H "$ROOT" -static -o gistatic "$T/gistatic.xc" -Wl,giextra.o ) \
        || bad "x86_64: $c could not build the static link"
done
cmp -s "$TMP/static-xcc/gistatic" "$TMP/static-xcc-xc/gistatic" || bad "x86_64: the two compilers' static gistatic differs"
HOST=${XTC_X86_HOST:-${XTC_LINUX_HOST:-}}
if [ -n "$HOST" ] && ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" true 2>/dev/null; then
    RD=/tmp/gistatic.$$
    ssh "$HOST" "rm -rf $RD && mkdir -p $RD" </dev/null
    scp -q "$TMP/static-xcc-xc/gistatic" "$HOST:$RD/"
    got=$(ssh "$HOST" "cd $RD && ./gistatic" </dev/null)
    ssh "$HOST" "rm -rf $RD" </dev/null
    [ "$got" = "$WANT_S" ] && echo "PASS  x86_64: a -static link keeps a global instance's header with it" || { bad "x86_64: static gistatic"; echo "$got"; }
fi

# order <target> <tag> <link flags...>: both compilers build gioa.o and giob.o
# and link giorder in both object orders into $TMP/order-<tag>/<cc>-<ab|ba>.
WANT_O_AB=$'square set up\ncircle set up\nmark set up\narea 49 radius 3 mark 9'
WANT_O_BA=$'circle set up\nsquare set up\nmark set up\narea 49 radius 3 mark 9'
order() {
    local a=$1 tag=$2; shift 2
    local d=$TMP/order-$tag c
    for c in xcc xcc-xc; do
        mkdir -p "$d/$c"
        ( cd "$d/$c" && "$BIN/$c" -q -A "$a" -H "$ROOT" -c -o gioa.o "$T/gioa.xc" \
            && "$BIN/$c" -q -A "$a" -H "$ROOT" -c -o giob.o "$T/giob.xc" \
            && "$BIN/$c" -q -A "$a" -H "$ROOT" "$@" -o ab "$T/giorder.xc" -Wl,gioa.o -Wl,giob.o \
            && "$BIN/$c" -q -A "$a" -H "$ROOT" "$@" -o ba "$T/giorder.xc" -Wl,giob.o -Wl,gioa.o ) \
            || bad "$tag: $c could not build the order links"
    done
    for c in gioa.o giob.o ab ba; do
        cmp -s "$d/xcc/$c" "$d/xcc-xc/$c" || bad "$tag: the two compilers' $c differ"
    done
}
# check_order <tag> <ab output> <ba output>
check_order() {
    [ "$2" = "$WANT_O_AB" ] && [ "$3" = "$WANT_O_BA" ] \
        && echo "PASS  $1: each object's global instance is set up before main, in link order" \
        || { bad "$1: order"; echo "$2"; echo "$3"; }
}
if [ "$(uname -s)" = Darwin ]; then
    order arm64 arm64
    check_order arm64 "$("$TMP/order-arm64/xcc-xc/ab")" "$("$TMP/order-arm64/xcc-xc/ba")"
fi
order x86_64 x86-static -static
order x86_64 x86-dynamic
if [ -n "$HOST" ] && ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" true 2>/dev/null; then
    RD=/tmp/giorder.$$
    ssh "$HOST" "rm -rf $RD && mkdir -p $RD/s $RD/d" </dev/null
    scp -q "$TMP/order-x86-static/xcc-xc/ab" "$TMP/order-x86-static/xcc-xc/ba" "$HOST:$RD/s/"
    scp -q "$TMP/order-x86-dynamic/xcc-xc/ab" "$TMP/order-x86-dynamic/xcc-xc/ba" "$HOST:$RD/d/"
    check_order "x86_64 -static" "$(ssh "$HOST" "$RD/s/ab" </dev/null)" "$(ssh "$HOST" "$RD/s/ba" </dev/null)"
    check_order "x86_64 dynamic" "$(ssh "$HOST" "$RD/d/ab" </dev/null)" "$(ssh "$HOST" "$RD/d/ba" </dev/null)"
    ssh "$HOST" "rm -rf $RD" </dev/null
fi
if command -v wine >/dev/null 2>&1; then
    WINEDEBUG=-all matrix win64 dll wine
    order win64 win64
    check_order win64 "$(cd "$TMP/order-win64/xcc-xc" && WINEDEBUG=-all wine ./ab 2>/dev/null | tr -d '\r')" \
        "$(cd "$TMP/order-win64/xcc-xc" && WINEDEBUG=-all wine ./ba 2>/dev/null | tr -d '\r')"
fi
[ $fail = 0 ] || exit 1
