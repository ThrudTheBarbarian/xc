#!/bin/bash
# chain.sh — a library that subclasses another library's class.
#
#   bash tests/crossmod/chain.sh
#
# chainbase.xc is a library with class Base (roots f, g). chainsub.xc is a
# second library that imports it and declares Sub : Base, overriding f and
# adding a root h. chainclient.xc imports both and calls a Sub through each.
# chainuse.xc is a third library that uses the first only inside its bodies
# and has startup code (a designable class's load-time constructor) that
# calls into the first. chainrev.xc imports it before the first library, and
# chainuseonly.xc imports it alone.
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
#   wasm32  the same matrix under node. The second library's vtable words
#           for Base$vtbl, Base$description and Base$g name the first
#           library's symbols; they were left 0, so b.g() was a null call.
#           The loader loaded only the libraries the app names, so
#           chainuseonly failed at instantiation ("ChainBase": module is not
#           an object), and it relocated them in the app's import order, so
#           chainrev's startup code called through the first library's
#           vtable before it was filled (null function). ChainU.many frees
#           a `new Base[N]` made in the third library: each element runs
#           the first library's Base$dealloc
#   x86_64  the three libraries, chainclient and chainmany on $XTC_X86_HOST /
#           $XTC_LINUX_HOST. Those vtable words are R_X86_64_64 relocations
#           against the first library's symbols; the second library did not
#           link before they were. chainmany calls ChainU.many only: the
#           third library takes the address of the imported Base$dealloc
#           through the GOT, and did not link before it did
# Not run:
#   arm9    running needs the loader tree and qemu
#   chainuseonly on arm64: the third library does not record that it needs
#           the first, so nothing loads it (dyld: symbol not found
#           '_UXNib$booted')
#   chainrev on x86_64: a library's load-time constructors never run, so
#           boot=0
#   chainuseonly on x86_64: as on arm64, the third library does not record
#           that it needs the first (undefined symbol UXNib$booted)
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${XCC_BIN:-$ROOT/bin/osx}"; [ -d "$BIN" ] || BIN="$ROOT/bin/linux"
T="$ROOT/tests/crossmod"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

WANT_chainclient=$'base=502\nsub=27\napp=705'
WANT_chainrev=$'boot=102\nmany=4\nbase=102'
WANT_chainuseonly=$'boot=102\nmany=3'
WANT_chainmany=$'many=4\nmany=2'

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

# runmatrix <target> <ext> <runner> <libs> <app>... — the libraries (<libs>,
# e.g. "Base Sub") from each compiler, and each app from each compiler
# against each set, built and run.
runmatrix() {
    local a=$1 x=$2 run=$3 libs=$4 L A d got app want l ok
    shift 4
    for L in xcc xcc-xc; do
        d="$TMP/run-$a/lib-$L"; mkdir -p "$d"; ok=1
        for l in $libs; do
            lib "$a" "$L" "$d" "libChain$l$x" "chain$(echo "$l" | tr 'A-Z' 'a-z')" 2>>"$d.err" || ok=0
        done
        [ $ok = 1 ] || { bad "$a: $L could not build the libraries"; sed 's/^/        /' "$d.err" | head -5; }
    done
    samefiles "$TMP/run-$a/lib-xcc" "$TMP/run-$a/lib-xcc-xc" $(ls "$TMP/run-$a/lib-xcc") \
        || bad "$a: the two compilers' libraries differ"
    for L in xcc xcc-xc; do
        for A in xcc xcc-xc; do
            for app in "$@"; do
                d="$TMP/run-$a/$L-$A-$app"
                mkdir -p "$d"; cp "$TMP/run-$a/lib-$L"/* "$d/"
                ( cd "$d" && "$BIN/$A" -A "$a" -H "$ROOT" -q -L . -o "$app" "$T/$app.xc" ) 2>"$d/err" \
                    || { bad "$a lib=$L app=$A $app: the app did not build"; continue; }
                got=$($run "$d" "$app" 2>&1)
                want=WANT_$app
                [ "$got" = "${!want}" ] || { bad "$a lib=$L app=$A $app:"; echo "$got" | head -5 | sed 's/^/        /'; }
            done
        done
    done
}
run_native() { ( cd "$1" && ./"$2" ); }
run_node()   { ( cd "$1" && node "$2.js" ); }
run_x86() {
    ssh "$HOST" "rm -rf $RD && mkdir -p $RD" </dev/null
    scp -q "$1/$2" "$1"/*.so "$HOST:$RD/"
    ssh "$HOST" "cd $RD && ./$2" </dev/null
}

before=$fail
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)
        # Not chainuseonly: a dylib does not load the libraries it imports.
        runmatrix arm64 .dylib run_native "Base Sub Use" chainclient chainrev
        [ $fail = $before ] && echo "PASS  arm64: run, lib x app compiler matrix" ;;
    *)  echo "SKIP  arm64 run: needs a macOS arm64 host" ;;
esac

before=$fail
if command -v node >/dev/null 2>&1; then
    runmatrix wasm32 "" run_node "Base Sub Use" chainclient chainrev chainuseonly
    [ $fail = $before ] && echo "PASS  wasm32: run under node, lib x app compiler matrix"
else
    echo "SKIP  wasm32 run: no node"
fi

before=$fail
HOST=${XTC_X86_HOST:-${XTC_LINUX_HOST:-}}
if [ -n "$HOST" ] && ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" true 2>/dev/null; then
    RD=/tmp/xc-chain-$$
    runmatrix x86_64 .so run_x86 "Base Sub Use" chainclient chainmany
    ssh "$HOST" "rm -rf $RD" </dev/null
    [ $fail = $before ] && echo "PASS  x86_64: run on $HOST, lib x app compiler matrix"
else
    echo "SKIP  x86_64 run: no x86-64 host reachable"
fi

echo "--- chain: $fail failing ---"
[ "$fail" = 0 ]
