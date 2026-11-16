//xtc-flags: target=arm64
// asm_writeback_cmp.xc — inline asm whose second compare reads a base a
// writeback load moved. The redundant-compare peephole took `ldr` as leaving
// both compare registers alone and dropped the second `cmp x1, x4`, so the
// csinc read the first compare's flags and the program printed 0 (#306).
#import "Stdio.xc"

i64 post()
    {
    i64 r = 0;
    asm {
        mov x1, sp
        add x4, x1, #8
        cmp x1, x4
        ldr x2, [x1], #8
        cmp x1, x4
        csinc x3, xzr, xzr, ne
        str x3, [r]
    }
    return r;
    }

i32 main()
    {
    Stdio.printf("%ld\n", post());
    return 0;
    }
