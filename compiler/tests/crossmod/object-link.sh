#!/bin/bash
# object-link.sh — a program linked with objects built with -c, where each
# module carries its own copy of the classes it uses, on every target this
# host can run.
#
#   bash tests/crossmod/object-link.sh
#
#   strings  olmain.xc linked with olstr.o (#654): the object prints with
#            Stdio.printf and works on Strings, the program makes no Stdio
#            call and dispatches on the object's String through Object*. The
#            link keeps one copy of each String symbol, so the two modules
#            lay out String's vtable alike, and the program's hash agrees
#            with the object's.
#   statics  simain.xc and siboth.xc linked with siobj.o (#655): a class's
#            static init runs before the first use of its statics, whichever
#            module makes it, and once. Base40's are used only in the object
#            (42, not 2); Counted's in the object, first by a global
#            instance's init before main, and in the program, which counts
#            the runs.
#
#   arm64   built and run here (macOS arm64 host)
#   x86_64  -static and dynamic, run on $XTC_X86_HOST / $XTC_LINUX_HOST
#   win64   run under wine
#   arm9    statics, the program built with -c as well and the objects
#           linked: built with $XTC_ARM9_SYSROOT, run on the XTOS loader under
#           qemu when the sysroot holds freertos-hosttest.elf
#
# Both compilers build every object and program; they are compared byte for
# byte, and the xc compiler's are run.
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

fail=0
bad() { echo "FAIL  $*"; fail=$((fail+1)); }
# Flags for every compile and link of the target being built (arm9's -L),
# and OBJLINK=1 to build the program with -c as well and link the objects
# (arm9, whose driver takes no -Wl, objects).
XFLAGS=()
OBJLINK=0

# build <target> <tag> <program> <objects...> -- <link flags...>: both
# compilers build each object (-c) and the program into $TMP/<tag>/<cc>.
build() {
    local a=$1 tag=$2 prog=$3; shift 3
    local objs=() flags=() o c f d=$TMP/$tag
    while [ $# -gt 0 ] && [ "$1" != -- ]; do objs+=("$1"); shift; done
    [ $# -gt 0 ] && shift
    flags=("$@")
    for c in xcc xcc-xc; do
        mkdir -p "$d/$c"
        local wl=()
        for o in "${objs[@]}"; do
            ( cd "$d/$c" && "$BIN/$c" -q -A "$a" -H "$ROOT" ${XFLAGS[@]+"${XFLAGS[@]}"} -c -o "$o.o" "$T/$o.xc" ) \
                || { bad "$tag: $c could not build $o.o"; return 1; }
            wl+=("-Wl,$o.o")
        done
        if [ "$OBJLINK" = 1 ]; then
            # The program built with -c too, and the objects linked.
            ( cd "$d/$c" && "$BIN/$c" -q -A "$a" -H "$ROOT" ${XFLAGS[@]+"${XFLAGS[@]}"} -c -o "${prog%.so}.o" "$T/${prog%.so}.xc" \
                && "$BIN/$c" -q -A "$a" -H "$ROOT" ${XFLAGS[@]+"${XFLAGS[@]}"} ${flags[@]+"${flags[@]}"} -o "$prog" "${prog%.so}.o" "${objs[@]/%/.o}" ) \
                || { bad "$tag: $c could not build $prog"; return 1; }
        else
            ( cd "$d/$c" && "$BIN/$c" -q -A "$a" -H "$ROOT" ${XFLAGS[@]+"${XFLAGS[@]}"} ${flags[@]+"${flags[@]}"} -o "$prog" "$T/${prog%.so}.xc" "${wl[@]}" ) \
                || { bad "$tag: $c could not build $prog"; return 1; }
        fi
    done
    for f in "${objs[@]/%/.o}" "$prog"; do
        cmp -s "$d/xcc/$f" "$d/xcc-xc/$f" || bad "$tag: the two compilers' $f differ"
    done
}
# check <tag> <what> <want> <got>
check() {
    [ "$4" = "$3" ] && echo "PASS  $1: $2" || { bad "$1: $2"; echo "$4" | head -8; }
}

WANT_STR=$'HELLO, OBJECT len 13 prefix 1 tail OBJECT\nreplaced hello, program\nhash agrees 1 equals 1'
STR_WHAT="an object's String methods and Stdio.printf, and the program's dispatch on its String"
WANT_SI='object 42'
WANT_SIB='before main 42 object 42 program 42 runs 1'
SI_WHAT="a class's static init runs once, before the first use from either module"
# statics <target> <tag> <ext> <runner...> -- <link flags...>
statics() {
    local a=$1 tag=$2 ext=$3; shift 3
    local run=() got
    while [ $# -gt 0 ] && [ "$1" != -- ]; do run+=("$1"); shift; done
    build "$a" "$tag" "simain$ext" siobj "$@" || return
    build "$a" "$tag" "siboth$ext" siobj "$@" || return
    [ ${#run[@]} -gt 0 ] || return 0
    got="$("${run[@]}" "$TMP/$tag/xcc-xc/simain$ext")"$'\n'"$("${run[@]}" "$TMP/$tag/xcc-xc/siboth$ext")"
    check "$tag" "$SI_WHAT" "$WANT_SI"$'\n'"$WANT_SIB" "$got"
}
run_here() { "$1"; }
run_wine() { ( cd "$(dirname "$1")" && WINEDEBUG=-all wine "./$(basename "$1")" 2>/dev/null | tr -d '\r' ); }
run_x86() {
    ssh "$HOST" "rm -rf $RD && mkdir -p $RD" </dev/null
    scp -q "$1" "$HOST:$RD/"
    ssh "$HOST" "$RD/$(basename "$1")" </dev/null
}
# run_arm9 <prog.so>: on the XTOS loader under qemu; the program's stdout
# picked out of the shell transcript.
run_arm9() {
    printf 'runhost %s\nexit\n' "$1" \
      | timeout 90 qemu-system-arm -M xilinx-zynq-a9 -display none -no-reboot -m 1024 \
          -chardev stdio,id=sh0 -semihosting-config enable=on,target=native,chardev=sh0 \
          -kernel "$SR/freertos-hosttest.elf" 2>/dev/null \
      | LC_ALL=C sed -e '1,/XTOS shell/d' | LC_ALL=C sed 's/^xtos\$ //' | LC_ALL=C sed -e '/^bye$/,$d' \
      | grep -av '^\[net\]' | LC_ALL=C sed 's/\r$//' | LC_ALL=C sed -e '/^$/d'
}

if [ "$(uname -s)" = Darwin ]; then
    build arm64 str-arm64 olmain olstr \
        && check arm64 "$STR_WHAT" "$WANT_STR" "$("$TMP/str-arm64/xcc-xc/olmain")"
    statics arm64 si-arm64 "" run_here
fi
build x86_64 str-x86s olmain olstr -- -static
build x86_64 str-x86d olmain olstr
HOST=${XTC_X86_HOST:-${XTC_LINUX_HOST:-}}
if [ -n "$HOST" ] && ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" true 2>/dev/null; then
    RD=/tmp/object-link.$$
    ssh "$HOST" "rm -rf $RD && mkdir -p $RD/s $RD/d" </dev/null
    scp -q "$TMP/str-x86s/xcc-xc/olmain" "$HOST:$RD/s/"
    scp -q "$TMP/str-x86d/xcc-xc/olmain" "$HOST:$RD/d/"
    check "x86_64 -static" "$STR_WHAT" "$WANT_STR" "$(ssh "$HOST" "$RD/s/olmain" </dev/null)"
    check "x86_64 dynamic" "$STR_WHAT" "$WANT_STR" "$(ssh "$HOST" "$RD/d/olmain" </dev/null)"
    statics x86_64 si-x86s "" run_x86 -- -static
    statics x86_64 si-x86d "" run_x86
    ssh "$HOST" "rm -rf $RD" </dev/null
else
    statics x86_64 si-x86s "" -- -static
    statics x86_64 si-x86d ""
fi
if command -v wine >/dev/null 2>&1; then
    build win64 str-win64 olmain olstr \
        && check win64 "$STR_WHAT" "$WANT_STR" \
            "$(cd "$TMP/str-win64/xcc-xc" && WINEDEBUG=-all wine ./olmain 2>/dev/null | tr -d '\r')"
    statics win64 si-win64 "" run_wine
fi
SR=${XTC_ARM9_SYSROOT:-}
if [ -n "$SR" ] && [ -d "$SR" ]; then
    XFLAGS=(-L "$SR"); OBJLINK=1
    if [ -f "$SR/freertos-hosttest.elf" ] && command -v qemu-system-arm >/dev/null 2>&1; then
        statics arm9 si-arm9 .so run_arm9
    else
        statics arm9 si-arm9 .so && echo "PASS  arm9: statics built and compared (not run: no loader kernel)"
    fi
    XFLAGS=(); OBJLINK=0
else
    echo "SKIP  arm9: no \$XTC_ARM9_SYSROOT"
fi
[ $fail = 0 ] || exit 1
