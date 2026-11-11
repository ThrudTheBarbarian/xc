#!/bin/bash
# xcargs.sh — the --xc-* options on a program's command line (#148). A program
# with a par block takes every argument starting `--xc-` out before main and
# sets the runtime variable it names: `--xc-par=cpu --xc-par-report` leave
# main's argv and Process.arguments() and make the block run on the CPU with
# the report on. `--` stops the scan (it and what follows reach main),
# `--xc-help` exits 0, `--xc-par-secret=x` and an unknown `--xc-zz` exit 2.
# -fno-xc-args, and a program without a par block, pass every argument
# through. An xc program and a C program (its loop lifted by
# --par-style=auto; skipped without clang). On Windows the command line
# GetCommandLineW returns is the filtered one too.
#
#   bash tests/par/xcargs.sh
#   XCARGS_A=x86_64-linux XCARGS_HOST=<linux host> bash tests/par/xcargs.sh
#   XCARGS_A=win64 XCARGS_HOST=<windows host> bash tests/par/xcargs.sh
#
# XCARGS_A cross-builds for that target; XCARGS_HOST runs the programs there
# over ssh (a Windows host's shell is PowerShell; the programs run under cmd).
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
TA=${XCARGS_A:-}
H=${XCARGS_HOST:-}
SSHO="-o BatchMode=yes -o LogLevel=ERROR"
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
WIN=0; EXE=""
case "$TA" in win64*) WIN=1; EXE=.exe ;; esac
AFLAG=(); [ -n "$TA" ] && AFLAG=(-A "$TA")
D="xcargs.$$"
if [ -n "$H" ]; then
    if [ $WIN = 1 ]; then
        ssh $SSHO "$H" "New-Item -ItemType Directory $D | Out-Null" || exit 1
        trap 'rm -rf "${W:?}"; ssh $SSHO "$H" "Remove-Item -Recurse -Force $D" >/dev/null 2>&1' EXIT
    else
        ssh $SSHO "$H" "mkdir -p /tmp/$D" || exit 1
        # A cross-built program finds libRuntime by the path it was built
        # with; there it is beside the programs, on LD_LIBRARY_PATH.
        for l in support/runtime-lib/"$TA"/libRuntime.*; do
            [ -f "$l" ] && scp $SSHO -q "$l" "$H:/tmp/$D/"
        done
        trap 'rm -rf "${W:?}"; ssh $SSHO "$H" "rm -rf /tmp/$D" >/dev/null 2>&1' EXIT
    fi
elif [ -n "$TA" ]; then
    echo "--- xcargs: XCARGS_A without XCARGS_HOST: built, not run ---"
fi

# run <program> <args...>: its stdout and stderr, then a last line "rc=<status>".
# Windows: under cmd, so `--` reaches the program as typed.
run() {
    local p=$1; shift
    if [ -z "$H" ]; then
        "$W/$p" "$@" 2>&1; echo "rc=$?"
    elif [ $WIN = 1 ]; then
        ssh $SSHO "$H" "cmd /c \"cd /d $D && $p$EXE $* 2>&1\"; \"rc=\$LASTEXITCODE\"" 2>&1 | tr -d '\r'
    else
        ssh $SSHO "$H" "cd /tmp/$D && LD_LIBRARY_PATH=. ./$p $* 2>&1; echo rc=\$?" 2>&1
    fi
}
status() {    # status <program> <args...>: the exit status alone
    run "$@" | sed -n 's/^rc=//p' | tail -1
}
send() {
    [ -z "$H" ] && return 0
    if [ $WIN = 1 ]; then scp $SSHO -q "$W/$1$EXE" "$H:$D/" ; else scp $SSHO -q "$W/$1" "$H:/tmp/$D/"; fi
}
build() {     # build <name> <source> <flags...>
    local n=$1 src=$2; shift 2
    "$XC" -q ${AFLAG[@]+"${AFLAG[@]}"} "$@" -o "$W/$n$EXE" "$src" > "$W/$n.b" 2>&1 \
        || { echo "FAIL xcargs: $n does not build: $(head -c 300 "$W/$n.b")"; fail=1; return 1; }
    [ -n "$TA" ] && [ -z "$H" ] && return 1
    send "$n"
}

cat > "$W/px.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
#define N 65536
u32 out[N];
#ifdef OS_windows
u16* GetCommandLineW(void);
#endif
i32 main(i32 argc, u8** argv)
    {
    par blk
        {
        for (u32 i in 0..(u32)N)
            out[i] = i * (u32)3;
        }
    Stdio.printf("argc=%d", argc);
    for (i32 i = 1; i < argc; i++)
        Stdio.printf(" [%s]", argv[i]);
    Array* pa = Process.arguments();
    Stdio.printf(" | args=%u", pa.count());
    for (u32 i = (u32)1; i < pa.count(); i++)
        Stdio.printf(" [%s]", ((String*)pa.get(i)).cString());
    Array* on = Par.ranOn("blk");
    Stdio.printf(" | %s %u\n", on.count() > (u32)0 ? ((String*)on.get((u32)0)).cString() : "-", out[(u32)(N - 1)]);
#ifdef OS_windows
    // The command line Windows hands out, as a GUI program reads it: the
    // options are gone from it too.
    u16* w = GetCommandLineW();
    u32 hits = (u32)0;
    for (u32 i = (u32)0; w[i] != (u16)0; i++)
        if (w[i] == (u16)'-' && w[i + (u32)1] == (u16)'-' && w[i + (u32)2] == (u16)'x' && w[i + (u32)3] == (u16)'c')
            hits++;
    Stdio.printf("cmdline-xc=%u\n", hits);
#endif
    return (i32)0;
    }
XC
cat > "$W/nopar.xc" <<'XC'
#import "Stdio.xc"
i32 main(i32 argc, u8** argv)
    {
    Stdio.printf("argc=%d", argc);
    for (i32 i = 1; i < argc; i++)
        Stdio.printf(" [%s]", argv[i]);
    Stdio.printf("\n");
    return (i32)0;
    }
XC
cat > "$W/pc.c" <<'C'
#include <stdio.h>
#define N 1000000
static int a[N];
int main(int argc, char **argv)
{
    for (int i = 0; i < N; i++)
        a[i] = i * 3;
    long long s = 0;
    for (int i = 0; i < N; i++)
        s += a[i];
    printf("argc=%d", argc);
    for (int i = 1; i < argc; i++)
        printf(" [%s]", argv[i]);
    printf(" | %lld\n", s);
    return 0;
}
C

check() {     # check <label> <output> <pattern>
    printf '%s\n' "$2" | grep -q -- "$3" || { echo "FAIL xcargs: $1: wanted '$3' in: $(printf '%s' "$2" | head -c 400)"; fail=1; }
}
nocheck() {   # nocheck <label> <output> <pattern>
    printf '%s\n' "$2" | grep -q -- "$3" && { echo "FAIL xcargs: $1: did not want '$3' in: $(printf '%s' "$2" | head -c 400)"; fail=1; }
}

if build px "$W/px.xc" -O2; then
    o=$(run px --xc-par=cpu a --xc-par-report b)
    check "xc: options out of argv" "$o" 'argc=3 \[a\] \[b\] | args=3 \[a\] \[b\] | cpu 196605'
    check "xc: --xc-par-report reports" "$o" '^par: '
    check "xc: exit status" "$o" 'rc=0'
    [ $WIN = 1 ] && check "xc: GetCommandLineW filtered" "$o" 'cmdline-xc=0'
    o=$(run px a -- --xc-par=cpu b)
    check "xc: -- stops the scan" "$o" 'argc=5 \[a\] \[--\] \[--xc-par=cpu\] \[b\] | args=5'
    nocheck "xc: -- stops the scan (no report)" "$o" '^par: '
    o=$(run px --xc-probe x)
    check "xc: --xc-probe" "$o" 'argc=2 \[x\]'
    o=$(run px --xc-help)
    check "xc: --xc-help lists" "$o" '--xc-par-report'
    check "xc: --xc-help lists" "$o" '--xc-par=cpu|gpu'
    nocheck "xc: --xc-help runs no main" "$o" 'argc='
    [ "$(status px --xc-help)" = 0 ] || { echo "FAIL xcargs: --xc-help does not exit 0"; fail=1; }
    [ "$(status px --xc-par-secret=x)" = 2 ] || { echo "FAIL xcargs: --xc-par-secret=x does not exit 2"; fail=1; }
    o=$(run px --xc-par-secret=x)
    check "xc: the secret refused" "$o" 'refused'
    nocheck "xc: the secret refused before main" "$o" 'argc='
    [ "$(status px --xc-zz)" = 2 ] || { echo "FAIL xcargs: --xc-zz does not exit 2"; fail=1; }
    o=$(run px --xc-zz)
    check "xc: unknown option named" "$o" 'xc: --xc-zz: unknown option'
fi
# The runtime compiled in as source (as a -static link has it): the same.
if build pxs "$W/px.xc" -O2 --no-runtime-lib; then
    o=$(run pxs --xc-par=cpu a --xc-par-report b)
    check "source runtime: options out of argv" "$o" 'argc=3 \[a\] \[b\] | args=3 \[a\] \[b\] | cpu 196605'
    check "source runtime: --xc-par-report reports" "$o" '^par: '
fi
if build pxn "$W/px.xc" -O2 -fno-xc-args; then
    o=$(run pxn --xc-par=cpu a --xc-zz)
    check "-fno-xc-args passes them through" "$o" 'argc=4 \[--xc-par=cpu\] \[a\] \[--xc-zz\]'
fi
if build nopar "$W/nopar.xc" -O2; then
    o=$(run nopar --xc-par=cpu a --xc-zz)
    check "no par block: passed through" "$o" 'argc=4 \[--xc-par=cpu\] \[a\] \[--xc-zz\]'
fi
if ! command -v clang > /dev/null; then
    echo "--- xcargs: the C program skipped (no clang) ---"
elif build pc "$W/pc.c" -O3 --par-style=auto -H .; then
    o=$(run pc --xc-par=cpu a --xc-par-report b)
    check "C: options out of argv" "$o" 'argc=3 \[a\] \[b\] | 1499998500000'
    check "C: --xc-par-report reports" "$o" '^par: '
    o=$(run pc a -- --xc-par=cpu)
    check "C: -- stops the scan" "$o" 'argc=4 \[a\] \[--\] \[--xc-par=cpu\]'
    [ "$(status pc --xc-zz)" = 2 ] || { echo "FAIL xcargs: C: --xc-zz does not exit 2"; fail=1; }
    if build pcn "$W/pc.c" -O3 --par-style=auto -H . -fno-xc-args; then
        o=$(run pcn --xc-par=cpu a)
        check "C: -fno-xc-args passes them through" "$o" 'argc=3 \[--xc-par=cpu\] \[a\]'
    fi
fi
[ $fail = 0 ] && echo "--- xcargs: pass${TA:+ ($TA${H:+ on $H})} ---"
exit $fail
