#import "Stdio.xc"
// A constant divisor or index reached through a narrowing cast (#308): the
// code generator followed ZExt/SExt/Trunc back to the literal without applying
// them, so (i32)(i8)300 divided by 300 instead of 44 at -O0/-O1.
i32 f(i32 x) { i8 d = (i8)300; return x / (i32)d; }
u32 g(u32 x) { u8 d = (u8)300; return x / (u32)d; }
i32 h(i32 x) { i8 d = (i8)200; return x / (i32)d; }
u32 k(u32 x) { i8 d = (i8)200; return x % (u32)(u8)d; }
u32 m(u32 x) { u16 d = (u16)70007; return x / (u32)d; }
i32 n(i32 x) { i16 d = (i16)65530; return x % (i32)d; }
u32 p(u32 x) { i8 d = (i8)250; return x / (u32)(u16)d; }
i32 main(i32 argc, u8** argv)
    {
    i32 x = 1000 + argc - 1;
    u8 arr[64];
    for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1) arr[i] = (u8)i;
    u8 j = (u8)300;
    Stdio.printf("%d %u %d %u %u %d %u %u\n", f(x), g((u32)x), h(x), k((u32)x), m((u32)x * (u32)9), n(x), p((u32)x * (u32)70), (u32)arr[(u32)j]);
    return 0;
    }
