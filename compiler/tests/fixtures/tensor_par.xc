// tensor_par.xc — a par block over a 2-D tensor on the CPU: each work item
// writes its own row of dst and reads src at another row. src and dst are of
// one element type, but each is made by its own `new` and never set again, so
// they are two storages and the block still runs in parallel (an explicit
// block the rules refused would not compile). The result is the same however
// the rows are split. The block has no GPU form yet, and says so.
//xtc-na: xt6502, m68k, arm9 — par has no threads there
//xtc-warn: it reads or writes tensor elements
#import "Stdio.xc"
#import "Par.xc"

i32 main(void)
    {
    u64 rows = 48;
    u64 cols = 20;
    tensor<i32, 2> src = new tensor<i32, 2>(rows, cols);
    tensor<i32, 2> dst = new tensor<i32, 2>(rows, cols);
    for (u64 i = 0; i < rows; i++)
        for (u64 j = 0; j < cols; j++)
            src[i, j] = (i32)(i * 3 + j);
    par rowsum
        {
        for (u64 i in 0..48)
            for (u64 j in 0..20)
                dst[i, j] = src[i, j] * 2 + src[47 - i, 19 - j];
        }
    i64 s = 0;
    for (u64 i = 0; i < rows; i++)
        for (u64 j = 0; j < cols; j++)
            s = s + (i64)dst[i, j];
    Stdio.printf("sum %ld\n", s);
    Stdio.printf("corner %d %d\n", dst[0, 0], dst[47, 19]);
    return 0;
    }
