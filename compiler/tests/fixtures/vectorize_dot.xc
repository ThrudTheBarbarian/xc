//xtc-flags: target=arm64
#import "Stdio.xc"
i32 main(void)
{
    u16 a[64];
    u16 b[64];
    for (i32 i = 0; i < 64; i = i + 1) { a[i] = (u16)i; b[i] = (u16)(i + 1); }
    u32 s = (u32)0;
    for (i32 i = 0; i < 64; i = i + 1) {
        u16 p = a[i] * b[i];
        s = s + (u32)p;
    }
    Stdio.printf("%lu\n", s);
    return 0;
}
