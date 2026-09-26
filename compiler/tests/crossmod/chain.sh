#!/bin/bash
# chain.sh — a library that subclasses another library's class.
#
#   bash tests/crossmod/chain.sh
#
# chainbase.xc is a library with class Base (roots f, g). chainsub.xc is a
# second library that imports it and declares Sub : Base, overriding f and
# adding a root h. chainclient.xc imports both and calls a Sub through each.
#
# Base's slots reach the second library as adopted numbers from the first
# library's interface. Its per-class numbering sized Base as its parent without
# them, so Sub's new root h took a slot of Base's (Base.f on arm64, x86_64 and
# arm9, where the app printed base=702, want 502).
#
# On every target:
#   - the slot map: Sub's vtable in the second library's IR holds Sub.f and
#     Base.g where Base's vtable in the first library holds Base.f and Base.g,
#     and Sub.h in the slot after (xcc-xc; xcc does not forward --emit-ir);
#   - the second library's assembly is the same from both compilers (on arm9,
#     both libraries' .so files, since the drivers' -S text differs in form).
# Run as well:
#   arm64   a lib x app compiler matrix, built and run here (macOS arm64 host)
# Not run:
#   x86_64  the second library does not link: its vtable names Base$vtbl and
#           Base$g as data, which the linker imports only through the GOT
#   wasm32  the second library's vtable leaves Base$g (and the Base$vtbl
#           ancestry word) null, so b.g() is a null call
#   arm9    running needs the loader tree and qemu
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${XCC_BIN:-$ROOT/bin/osx}"; [ -d "$BIN" ] || BIN="$ROOT/bin/linux"
T="$ROOT/tests/crossmod"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

WANT=$'base=502\nsub=27\napp=705'

fail=0
bad() { echo "FAIL  $*"; fail=$((fail+1)); }

# flags <target> — the arm9 standard library needs the sysroot's libc.so.
flags() { [ "$1" = arm9 ] && [ -n "${XTC_ARM9_SYSROOT:-}" ] && echo "-L $XTC_ARM9_SYSROOT"; }

# lib <target> <compiler> <dir> <out> <src> [flags] — one library, in <dir>.
lib() {
    local a=$1 c=$2 d=$3 out=$4 src=$5; shift 5
    mkdir -p "$d"
    ( cd "$d" && "$BIN/$c" --emit-lib -A "$a" -H "$ROOT" -q -L . $(flags "$a") "$@" -o "$out" "$T/$src.xc" )
}
samefiles() {  # <dir1> <dir2> <file>...
    local d1=$1 d2=$2; shift 2
    for f in "$@"; do cmp -s "$d1/$f" "$d2/$f" || return 1; done
}
# vtable <ir> <class> — the class's vtable entries, one per line.
vtable() {
    grep "^  symbol $2\\\$vtbl: vtable \[" "$1" | sed 's/.*\[//; s/\].*//' | tr -d ' ' | tr ',' '\n'
}

# check <target> <ext> — the slot map and the two compilers' assembly.
check() {
    local a=$1 x=$2 c d base sub
    for c in xcc xcc-xc; do
        d="$TMP/$a/$c"; mkdir -p "$d"
        lib "$a" "$c" "$d" "libChainBase$x" chainbase 2>"$d.err" \
            || { bad "$a: $c could not build the first library"; sed 's/^/        /' "$d.err" | head -5; return; }
        lib "$a" "$c" "$d" sub.s chainsub -S 2>"$d.err" \
            || { bad "$a: $c could not compile the second library"; sed 's/^/        /' "$d.err" | head -5; return; }
        # arm9: the two drivers' -S text differs in form, so compare the .so.
        if [ "$a" = arm9 ]; then
            lib "$a" "$c" "$d" libChainSub.so chainsub 2>"$d.err" \
                || { bad "$a: $c could not build the second library"; sed 's/^/        /' "$d.err" | head -5; return; }
        fi
    done
    if [ "$a" = arm9 ]; then
        samefiles "$TMP/$a/xcc" "$TMP/$a/xcc-xc" libChainBase.so libChainSub.so \
            || bad "$a: the two compilers' libraries differ"
    else
        cmp -s "$TMP/$a/xcc/sub.s" "$TMP/$a/xcc-xc/sub.s" || bad "$a: the two compilers' second library differs"
    fi
    d="$TMP/$a/xcc-xc"
    lib "$a" xcc-xc "$d" base.s chainbase -S --emit-ir-opt 2>"$d/base.ir" &&
    lib "$a" xcc-xc "$d" sub.s chainsub -S --emit-ir-opt 2>"$d/sub.ir" \
        || { bad "$a: xcc-xc could not print the libraries' IR"; return; }
    base=$(vtable "$d/base.ir" Base | awk '$0=="Base$f"||$0=="Base$g"{print NR": "$0; last=NR} END{print last+1": Sub$h"}' | sed 's/Base\$f/Sub$f/')
    sub=$(vtable "$d/sub.ir" Sub | awk '$0=="Sub$f"||$0=="Base$g"||$0=="Sub$h"{print NR": "$0}')
    if [ -z "$sub" ] || [ "$sub" != "$base" ]; then
        bad "$a: Sub's slots in the second library, want:"
        echo "$base" | sed 's/^/        /'; echo "      got:"; echo "$sub" | sed 's/^/        /'
    fi
}

for spec in arm64:.dylib x86_64:.so arm9:.so wasm32:; do
    a=${spec%%:*}; x=${spec#*:}
    before=$fail
    check "$a" "$x"
    [ $fail = $before ] && echo "PASS  $a: Sub's slot map, and the two compilers agree"
done

before=$fail
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)
        for L in xcc xcc-xc; do
            d="$TMP/run/lib-$L"; mkdir -p "$d"
            { lib arm64 "$L" "$d" libChainBase.dylib chainbase &&
              lib arm64 "$L" "$d" libChainSub.dylib chainsub; } 2>"$d.err" \
                || { bad "arm64: $L could not build the libraries"; continue; }
        done
        samefiles "$TMP/run/lib-xcc" "$TMP/run/lib-xcc-xc" libChainBase.dylib libChainSub.dylib \
            || bad "arm64: the two compilers' libraries differ"
        for L in xcc xcc-xc; do
            for A in xcc xcc-xc; do
                d="$TMP/run/$L-$A"
                mkdir -p "$d"; cp "$TMP/run/lib-$L"/*.dylib "$d/"
                ( cd "$d" && "$BIN/$A" -A arm64 -H "$ROOT" -q -L . -o chainclient "$T/chainclient.xc" ) 2>"$d/err" \
                    || { bad "arm64 lib=$L app=$A: the app did not build"; continue; }
                got=$( cd "$d" && ./chainclient 2>&1 )
                [ "$got" = "$WANT" ] || { bad "arm64 lib=$L app=$A:"; echo "$got" | sed 's/^/        /'; }
            done
        done
        [ $fail = $before ] && echo "PASS  arm64: run, lib x app compiler matrix" ;;
    *)  echo "SKIP  arm64 run: needs a macOS arm64 host" ;;
esac

echo "--- chain: $fail failing ---"
[ "$fail" = 0 ]
