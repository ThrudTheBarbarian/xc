//xtc-flags: target=arm64
#import "Stdio.xc"
i32 main(void)
{
    i32 a[64];
    for (i32 i = 0; i < 64; i = i + 1) a[i] = i;
    i32 s = 0;
    for (i32 i = 0; i < 64; i = i + 1) s = s + a[i];
    Stdio.printf("%ld\n", s);
    return 0;
}
