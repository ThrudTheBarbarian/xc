// mul_distribute — (b + c) * k beside b * k shares one multiply (2026-10-31).
// call_depth's inlined leaf(x) .. leaf(x + 3) multiplied each by 3 (four vector
// multiplies a turn, where clang has one); a 32-bit vector multiply is one
// pipe at half rate on a Cortex-A76. Each becomes x * 3 + 3c. The answers
// must be unchanged, wrap-around included (x near 2^32).
#import "Stdio.xc"
u32 leaf(u32 x)  { return (x * (u32)3) ^ (x >> (u32)2); }
u32 mid(u32 x)   { return leaf(x) + leaf(x + (u32)1); }
u32 outer(u32 x) { return mid(x) ^ mid(x + (u32)2); }
u16 narrow(u16 x) { return (u16)((x + (u16)7) * (u16)5) + (u16)(x * (u16)5); }
i32 main(i32 argc, u8** argv)
    {
    u32 acc = (u32)0;
    for (u32 r = (u32)0; r < (u32)1000; r++) acc = acc + outer(r + (u32)argc);
    u32 hi = (u32)4294967290 + (u32)argc;
    Stdio.printf("%u %u %u\n", acc, outer(hi), (u32)narrow((u16)65530 + (u16)argc));
    return 0;
    }
