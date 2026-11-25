#!/bin/bash
# sqrt-o0.sh — Math.sqrt returns at -O0 on x86-64 and win64 (#672). At -O0
# the call reaches the runtime's sqrt and sqrtf, which there jumped to
# themselves forever; -O2 used the instruction and never called them. A
# float and a double square root, built at -O0 and -O2, each run with a
# time limit: on x86-64 Linux here or on XC_LINUX_HOST from macOS, and on
# XTC_WIN64_HOST for win64 (each skipped when there is nowhere to run it).
#
#   [XC_LINUX_HOST=<host>] [XTC_WIN64_HOST=<host>] bash tests/driver/sqrt-o0.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
SSHO="-o BatchMode=yes -o LogLevel=ERROR"
cat > "$W/sq.xc" <<'SRC'
#import "Stdio.xc"
#import "Math.xc"
i32 main(void)
{
    float y = 2.71875;
    double d = 7.5d;
    double big = 1.0e10d;
    float zero = 0.0;
    Stdio.printf("%f %f %.1f %f\n", Math.sqrt(y), Math.sqrt(d), Math.sqrt(big), Math.sqrt(zero));
    return 0;
}
SRC
want="1.648863 2.738613 100000.0 0.000000"
fail=0
ran=""
# x86-64 Linux
LH=${XC_LINUX_HOST:-}
if [ "$PLAT" = linux ] && [ "$(uname -m)" = x86_64 ]; then LH=local; fi
if [ -n "$LH" ]; then
    for O in -O0 -O2; do
        "$XC" -q $O -H . -A x86_64 -o "$W/sq$O" "$W/sq.xc" > "$W/b" 2>&1 || { echo "FAIL sqrt-o0 (x86-64 $O): no build: $(head -c 300 "$W/b")"; fail=1; continue; }
        if [ "$LH" = local ]; then
            got=$(timeout 20 "$W/sq$O" 2>&1)
        else
            RD=$(ssh $SSHO "$LH" 'mktemp -d /tmp/xc-sqrt.XXXXXX') || { echo "sqrt-o0: cannot reach $LH, x86-64 skipped"; break; }
            scp $SSHO -q "$W/sq$O" "$LH:$RD/sq" && got=$(ssh $SSHO "$LH" "timeout 20 $RD/sq; rm -rf $RD" 2>&1)
        fi
        [ "$got" = "$want" ] || { echo "FAIL sqrt-o0 (x86-64 $O): '$got', wanted '$want'"; fail=1; }
    done
    ran="$ran x86-64"
fi
# win64
WH=${XTC_WIN64_HOST:-}
if [ -n "$WH" ]; then
    WD="xc-sqrt-$$-$RANDOM"
    if ssh $SSHO "$WH" "New-Item -ItemType Directory $WD | Out-Null"; then
        for O in -O0 -O2; do
            "$XC" -q $O -H . -A win64 -o "$W/sq$O.exe" "$W/sq.xc" > "$W/b" 2>&1 || { echo "FAIL sqrt-o0 (win64 $O): no build"; fail=1; continue; }
            scp $SSHO -q "$W/sq$O.exe" "$WH:$WD/sq$O.exe"
            got=$(ssh $SSHO "$WH" "cd $WD; \$p = Start-Process -FilePath .\\sq$O.exe -NoNewWindow -PassThru -RedirectStandardOutput o$O.txt; if (\$p.WaitForExit(20000)) { Get-Content o$O.txt } else { \$p.Kill(); 'timed out' }" 2>&1 | tr -d '\r')
            [ "$got" = "$want" ] || { echo "FAIL sqrt-o0 (win64 $O): '$got', wanted '$want'"; fail=1; }
        done
        ssh $SSHO "$WH" "Remove-Item -Recurse -Force $WD" > /dev/null 2>&1
        ran="$ran win64"
    else
        echo "sqrt-o0: cannot reach $WH, win64 skipped"
    fi
fi
[ -n "$ran" ] || { echo "--- sqrt-o0: skipped (no x86-64 or win64 host) ---"; exit 0; }
[ $fail = 0 ] && echo "--- sqrt-o0: pass ($ran ) ---"
exit $fail
