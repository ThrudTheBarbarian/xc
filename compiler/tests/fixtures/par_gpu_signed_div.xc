// par_gpu_signed_div.xc — signed division and REMAINDER by a negative divisor,
// at 32 and at 64 bits, in a `par` block.
//
// Guard for bug 649. The SPIR-V printer carried the signedness on the
// OPERATION (OpSDiv against OpUDiv) and held one unsigned integer type a width;
// the NVIDIA Vulkan driver reads the operand type's signedness as the
// operation's for the remainder and computed the UNSIGNED one, so `v % d` with
// d negative came back as v itself on one side of the sum and as the CPU's
// answer on the other (srem 2488825656611424 against 1175 in the smaller
// reproducer). Division was right; only the remainder was wrong, at both
// widths, and RADV did not show it. The remainder is now emitted the way C
// defines it — `a - (a/b)*b` — which reads correctly on every driver.
// The GPU's answer must be the CPU's, exactly.
#import "Stdio.xc"
#import "Par.xc"

i32 main(void)
    {
    i64 t64 = (i64)0;
    i32 t32 = (i32)0;
    par work :reduce(+ t64) :reduce(+ t32)
        {
        for (u32 i in 0..64)
            {
            i64 v = (i64)i * (i64)1234567890123 - (i64)987654321;
            i64 d = (i64)0 - ((i64)i + (i64)3);
            t64 = t64 + (v / d) * (i64)7 + (v % d);
            i32 w = (i32)100000 - (i32)i * (i32)1234;
            i32 e = (i32)0 - ((i32)i + (i32)3);
            t32 = t32 + (w / e) * (i32)7 + (w % e);
            }
        }
    Stdio.printf("t64 %lld t32 %d\n", t64, t32);
    return (i32)0;
    }
