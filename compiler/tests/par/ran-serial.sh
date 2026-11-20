#!/bin/bash
# ran-serial.sh — Par.ranOn says "serial" when the runtime ran a block item
# after item because the pool could change its answer (#462). A block that fell
# back to serial because two of its arrays overlapped recorded "cpu", like a
# run on the thread pool, which made a serial slowdown look like a pool problem
# (#453). A CPU run on one thread is still "cpu", so a program's output is the
# same at every thread count (tests/par/threads.sh). Checked, on one block run
# four times: arrays apart (cpu), overlapping with one written (serial), apart
# again (cpu), one item (cpu); and the same with XC_PAR_THREADS=1.
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export HOME="$W/home"; mkdir -p "$HOME"
if [ "$PLAT" = osx ]; then export DYLD_LIBRARY_PATH=support/runtime-lib/arm64-macos; else export LD_LIBRARY_PATH=support/runtime-lib/$(uname -m | sed 's/aarch64/arm64/')-linux; fi
fail=0
cat > "$W/r.xc" <<'XC'
#import "Stdio.xc"
#import "Par.xc"
void step(float* a, float* b, u32 n)
{
    par shift
    {
        for (u32 i in 0..n)
            b[i] = a[i] + 1.0f;
    }
}
u8* first(u8* name)
{
    Array* on = Par.ranOn(name);
    return on.count() > (u32)0 ? ((String*)on.get((u32)0)).cString() : "-";
}
i32 main(void)
{
    u32 n = 4096;
    float* a = new float[n + 1];
    float* b = new float[n];
    Par.device("shift", "cpu");
    step(a, b, n);
    Stdio.printf("%s", first("shift"));
    step(a, a + 1, n);
    Stdio.printf(" %s", first("shift"));
    step(a, b, n);
    Stdio.printf(" %s", first("shift"));
    step(a, b, (u32)1);
    Stdio.printf(" %s\n", first("shift"));
    return 0;
}
XC
"$XC" -q -O2 -H . -o "$W/r" "$W/r.xc" > "$W/b" 2>&1 || { echo "FAIL ran-serial: does not build"; tail -3 "$W/b"; exit 1; }
got=$("$W/r" 2>/dev/null)
[ "$got" = "cpu serial cpu cpu" ] || { echo "FAIL ran-serial: apart, overlap, apart, one item ran on '$got', want 'cpu serial cpu cpu'"; fail=1; }
got=$(XC_PAR_THREADS=1 "$W/r" 2>/dev/null)
[ "$got" = "cpu serial cpu cpu" ] || { echo "FAIL ran-serial: XC_PAR_THREADS=1 ran on '$got', want 'cpu serial cpu cpu'"; fail=1; }
[ $fail = 0 ] && echo "ran-serial: ok"
exit $fail
