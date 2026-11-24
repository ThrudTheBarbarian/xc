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
#
#   arm64   built and run here (macOS arm64 host)
#   x86_64  -static and dynamic, run on $XTC_X86_HOST / $XTC_LINUX_HOST
#   win64   run under wine
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
            ( cd "$d/$c" && "$BIN/$c" -q -A "$a" -H "$ROOT" -c -o "$o.o" "$T/$o.xc" ) \
                || { bad "$tag: $c could not build $o.o"; return 1; }
            wl+=("-Wl,$o.o")
        done
        ( cd "$d/$c" && "$BIN/$c" -q -A "$a" -H "$ROOT" ${flags[@]+"${flags[@]}"} -o "$prog" "$T/$prog.xc" "${wl[@]}" ) \
            || { bad "$tag: $c could not build $prog"; return 1; }
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

if [ "$(uname -s)" = Darwin ]; then
    build arm64 str-arm64 olmain olstr \
        && check arm64 "$STR_WHAT" "$WANT_STR" "$("$TMP/str-arm64/xcc-xc/olmain")"
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
    ssh "$HOST" "rm -rf $RD" </dev/null
fi
if command -v wine >/dev/null 2>&1; then
    build win64 str-win64 olmain olstr \
        && check win64 "$STR_WHAT" "$WANT_STR" \
            "$(cd "$TMP/str-win64/xcc-xc" && WINEDEBUG=-all wine ./olmain 2>/dev/null | tr -d '\r')"
fi
[ $fail = 0 ] || exit 1
