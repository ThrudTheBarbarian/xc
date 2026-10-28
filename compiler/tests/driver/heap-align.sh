#!/bin/bash
# heap-align.sh — a numeric heap array of 1 KB or more starts on a 64-byte
# cache line (2026-10-28)
# calloc gives 16-byte alignment and the header put the data 40 bytes past
# it, so the 64-byte loads of a vector loop over a `new u32[N]` split across
# two lines for most placements, as the stack and global arrays did. Such an
# array now takes the page-aligned block's shape (magic, the allocator's base
# kept before the header) without the GPU registry. The program checks every
# large u32 and double array is aligned, that .length and the data are right,
# frees 200000 arrays of every size around the threshold, and that a bounds
# check still reads such a block's header (an out-of-range index traps).
# Runs on this host and, with XTC_X86_HOST, on an x86-64 one.
#
#   [XTC_X86_HOST=<host>] bash tests/driver/heap-align.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/ha.xc" <<'XC'
#import "Stdio.xc"

i32 main(i32 argc, u8** argv)
{
    u32 off = 0;
    u64 total = 0;
    for (u32 n = 1; n < 20000; n = n + 97)
    {
        u32* p = new u32[n];
        double* d = new double[n];
        for (u32 i = 0; i < n; i = i + 1)
        {
            p[i] = i + (u32)argc;
            d[i] = (double)i;
        }
        u64 s = 0;
        for (u32 i = 0; i < n; i = i + 1)
            s = s + (u64)p[i] + (u64)d[i];
        if ((u32)p.length != n || (u32)d.length != n)
            Stdio.printf("bad length %u\n", n);
        total = total + s;
        if (n * (u32)4 >= (u32)1024 && (((u64)(pointer)p) & (u64)63) != (u64)0)
            off = off + (u32)1;
        if (n * (u32)8 >= (u32)1024 && (((u64)(pointer)d) & (u64)63) != (u64)0)
            off = off + (u32)1;
    }
    for (u32 k = 0; k < 200000; k = k + 1)
    {
        u8* b = new u8[(k & (u32)4095) + (u32)1];
        b[0] = (u8)k;
        total = total + (u64)b[0];
    }
    Stdio.printf("%u %lu\n", off, total);
    return 0;
}
XC
cat > "$W/oob.xc" <<'XC'
#import "Stdio.xc"

i32 main(i32 argc, u8** argv)
{
    u32* p = new u32[1000];
    p[999] = 1;
    u32 i = (u32)999 + (u32)argc;
    p[i] = 2;
    Stdio.printf("not trapped\n");
    return 0;
}
XC
WANT="0 27646842456"
check() {  # label, output of the program
    [ "$2" = "$WANT" ] || { echo "FAIL heap-align ($1): got '$2', want '$WANT' (alignment misses, sum)"; fail=1; }
}
oobcheck() {  # label, status, stderr
    { [ "$2" != 0 ] && printf '%s' "$3" | grep -q 'out-of-bounds'; } \
        || { echo "FAIL heap-align ($1): an index past a 1 KB array did not trap (status $2)"; fail=1; }
}
"$XC" -q -O2 -o "$W/ha" "$W/ha.xc" || { echo "FAIL: does not build"; exit 1; }
"$XC" -q -O2 -fbounds-check -o "$W/oob" "$W/oob.xc" || { echo "FAIL: the bounds-checked program does not build"; exit 1; }
check "$(uname -m)" "$("$W/ha")"
err=$("$W/oob" 2>&1 >/dev/null); st=$?; oobcheck "$(uname -m)" $st "$err"
msg="$(uname -m)"
H=${XTC_X86_HOST:-}
if [ -n "$H" ] && [ "$(uname -m)" != x86_64 ]; then
    "$XC" -q -A x86_64 -O2 -o "$W/ha.x" "$W/ha.xc" || { echo "FAIL: does not build for x86-64"; exit 1; }
    "$XC" -q -A x86_64 -O2 -fbounds-check -o "$W/oob.x" "$W/oob.xc" || { echo "FAIL: the bounds-checked program does not build for x86-64"; exit 1; }
    SSHO="-o BatchMode=yes -o LogLevel=ERROR"
    scp $SSHO -q "$W/ha.x" "$H:heap-align.bin" && scp $SSHO -q "$W/oob.x" "$H:heap-align-oob.bin" || { echo "FAIL: copy to $H"; exit 1; }
    check x86_64 "$(ssh $SSHO "$H" './heap-align.bin')"
    err=$(ssh $SSHO "$H" './heap-align-oob.bin 2>&1 >/dev/null; s=$?; rm -f heap-align.bin heap-align-oob.bin; exit $s'); st=$?; oobcheck x86_64 $st "$err"
    msg="$msg and x86_64"
fi
[ $fail = 0 ] && echo "heap-align: ok ($msg)"
exit $fail
