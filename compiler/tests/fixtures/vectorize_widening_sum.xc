//xtc-flags: target=arm64
#import "Stdio.xc"
i32 main(void)
{
    u8 a[64];
    for (i32 i = 0; i < 64; i = i + 1) a[i] = (u8)i;
    u32 s = (u32)0;
    for (i32 i = 0; i < 64; i = i + 1) s = s + (u32)a[i];
    Stdio.printf("%lu\n", s);
    return 0;
}
