//xtc-flags: target=arm64
// `.length` of a RUNTIME-sized heap array is a real header read (docs/
// bugs/045, remedy 1): the `_xtc_count` runtime helper reads the element
// count the allocator wrote, so `new u16[n]` with a computed n finally has
// a length — and `for (v in buf)` over the same pointer gets its count the
// same way. The literal path still constant-folds (the `static=` probe).
// target=arm64: the xt6502's primitive-array allocator stores no count, so
// it keeps the compile-time diagnostic — the spec §3.4.2 note.
#use Stdio

u16 pick(void) { return (u16)37; }

i32 main(void)
{
    u16 n = pick();
    u16* buf = new u16[n];
    for (u16 i = (u16)0; i < n; i++) buf[i] = i + (u16)$100;
    Stdio.printf("len=%d last=%x\n", (u16)buf.length, buf[buf.length - (u16)1]);
    u64 sum = (u64)0;
    for (u16 v in buf) sum = sum + (u64)v;
    Stdio.printf("sum=%llu static=%d\n", sum, (u16)(new u8[64]).length);
    delete buf;
    return 0;
}
