// cmp_wide_imm — a loop's compare against a wide immediate (2026-10-31).
// arm64's cmp takes a 12-bit immediate (optionally shifted by 12); a bound
// such as 2200000000 was rebuilt with movz + movk every turn of the loop. On
// arm64 ConstHoist puts it in a Const before the loop. The answers are the
// same. (A loop starting above 2^31 that the vectoriser takes is left out:
// the two compilers' vectorisers differ on it, a separate TODO item.)
#import "Stdio.xc"
i32 main(i32 argc, u8** argv)
    {
    u32 acc = (u32)argc;
    u32 odd = (u32)0;
    for (u32 r = (u32)0; r < (u32)70000; r++)
        {
        if ((r & (u32)1) == (u32)1)
            odd = odd + r;
        else
            odd = odd ^ r;
        }
    Stdio.printf("%u %u\n", acc, odd);
    return 0;
    }
