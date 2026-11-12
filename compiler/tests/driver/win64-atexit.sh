#!/bin/bash
# win64-atexit.sh — a win64 program ends through the C library's exit (#151):
# what atexit registered runs, last first, after main returns; the C
# library's buffered stdout reaches a pipe without an fflush; main's value is
# the exit status. A C program calling atexit links (ucrtbase exports no
# atexit). An xc program registers a function of its own through atexit, and
# both compilers link it to the same bytes.
#
# The programs run under wine where there is one, and on a Windows host over
# ssh when XTC_WIN64_HOST names it (its shell is PowerShell).
#
#   bash tests/driver/win64-atexit.sh
#   XTC_WIN64_HOST=<windows host> bash tests/driver/win64-atexit.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
export WINEDLLOVERRIDES="winedbg.exe=d;${WINEDLLOVERRIDES:-}"
WH=${XTC_WIN64_HOST:-}
SSHO="-o BatchMode=yes -o LogLevel=ERROR"
fail=0; ran=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
D="w64atexit.$$"
if [ -n "$WH" ]; then
    ssh $SSHO "$WH" "New-Item -ItemType Directory $D | Out-Null" || { echo "FAIL win64-atexit: cannot reach $WH"; exit 1; }
    trap 'rm -rf "$W"; ssh $SSHO "$WH" "Remove-Item -Recurse -Force $D" >/dev/null 2>&1' EXIT
fi

# expect <label> <exe> <wanted output> <wanted status>: under wine, then on
# the Windows host. Output through a pipe, so the C library buffers it.
expect() {
    local label=$1 exe=$2 want=$3 wst=$4 got st
    if command -v wine >/dev/null 2>&1; then
        got=$(cd "$W" && WINEDEBUG=-all timeout 120 wine "./$exe" 2>/dev/null | tr -d '\r'; echo "rc=${PIPESTATUS[0]}")
        st=$(printf '%s\n' "$got" | sed -n 's/^rc=//p'); got=$(printf '%s\n' "$got" | sed '/^rc=/d')
        [ "$got" = "$want" ] && [ "$st" = "$wst" ] || { echo "FAIL win64-atexit: $label under wine: '$got' status $st"; fail=1; }
        ran=1
    fi
    if [ -n "$WH" ]; then
        scp $SSHO -q "$W/$exe" "$WH:$D/" || { echo "FAIL win64-atexit: cannot copy $exe"; fail=1; return; }
        got=$(ssh $SSHO "$WH" "cd $D; \$o = & .\\$exe | Out-String; \$o.TrimEnd(); \"rc=\$LASTEXITCODE\"" 2>&1 | tr -d '\r')
        st=$(printf '%s\n' "$got" | sed -n 's/^rc=//p'); got=$(printf '%s\n' "$got" | sed '/^rc=/d')
        [ "$got" = "$want" ] && [ "$st" = "$wst" ] || { echo "FAIL win64-atexit: $label on Windows: '$got' status $st"; fail=1; }
        ran=1
    fi
}

cat > "$W/t.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
static void one(void) { puts("one"); }
static void two(void) { puts("two"); }
int main(void)
{
    atexit(one);
    atexit(two);
    printf("main\n");
    return 7;
}
C
cat > "$W/x.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
static void bye(void) { puts("bye"); }
static void leave(int v) { exit(v); }
int main(void)
{
    atexit(bye);
    printf("main\n");
    leave(5);
    return 0;
}
C
cat > "$W/a.xc" <<'XC'
#import "Stdio.xc"
i32 atexit(pointer f);
i32 puts(u8* s);
void bye(void) { puts("bye"); }
i32 main(void)
    {
    atexit((pointer)&bye);
    Stdio.printf("main\n");
    return (i32)3;
    }
XC

XC1=${XC:-bin/$PLAT/xcc-xc}; XC1=${XC1%% *}
if ! command -v clang >/dev/null 2>&1; then
    echo "--- win64-atexit: the C programs skipped (no clang) ---"
else
    for p in t x; do
        "$XC1" -q -A win64 -H . -o "$W/$p.exe" "$W/$p.c" > "$W/$p.out" 2>&1 \
            || { echo "FAIL win64-atexit: $p.c does not link: $(head -c 300 "$W/$p.out")"; fail=1; }
    done
    [ -f "$W/t.exe" ] && expect "atexit, last first, status from main" t.exe "main
two
one" 7
    [ -f "$W/x.exe" ] && expect "exit from C runs atexit" x.exe "main
bye" 5
fi
prev=""
for XC in ${XC:-bin/$PLAT/xcc-xc bin/$PLAT/xcc}; do
    [ -x "$XC" ] || continue
    n=$(basename "$XC")
    "$XC" -q -A win64 -H . -o "$W/a.$n.exe" "$W/a.xc" > "$W/a.$n.out" 2>&1 \
        || { echo "FAIL win64-atexit: $n: a.xc does not link: $(head -c 300 "$W/a.$n.out")"; fail=1; continue; }
    if [ -n "$prev" ] && ! cmp -s "$W/a.$prev.exe" "$W/a.$n.exe"; then
        echo "FAIL win64-atexit: $prev and $n link a.xc to different bytes"; fail=1
    fi
    prev=$n
    expect "xc: atexit runs after main ($n)" "a.$n.exe" "main
bye" 3
done
[ $ran = 0 ] && echo "--- win64-atexit: built only (no wine, no XTC_WIN64_HOST) ---"
[ $fail = 0 ] && echo "win64-atexit: ok"
exit $fail
