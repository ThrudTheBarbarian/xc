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
#
#   arm64   built and run here (macOS arm64 host)
#   win64   the library matrix under wine
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
if command -v wine >/dev/null 2>&1; then
    WINEDEBUG=-all matrix win64 dll wine
fi
[ $fail = 0 ] || exit 1
