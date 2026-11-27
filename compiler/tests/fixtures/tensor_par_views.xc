// tensor_par_views.xc — par blocks over views of one storage, on the CPU.
// Two slices that split a tensor's first dimension at the same place are
// proved apart, so one block writes both. A block that writes a view and
// reads another view of the same storage at the written row checks, as it
// starts, whether the two overlap in another layout; these do, so it runs on
// one thread, as the source reads, and the result is the serial one. A
// block writing a column slice reads a fresh tensor anywhere.
//xtc-na: xt6502, m68k, arm9 — par has no threads there
//xtc-warn: it reads or writes tensor elements
#import "Stdio.xc"
#import "Par.xc"

i64 total(tensor<i32, 2> t)
    {
    i64 s = 0;
    for (u64 i = 0; i < t.shape(0); i++)
        for (u64 j = 0; j < t.shape(1); j++)
            s = s + (i64)t[i, j];
    return s;
    }

i32 main(void)
    {
    tensor<i32, 2> t = new tensor<i32, 2>(64, 8);
    u64 h = 32;
    tensor<i32, 2> top = t[0..h, ..];
    tensor<i32, 2> bottom = t[h.., ..];
    par halves
        {
        for (u64 i in 0..32)
            for (u64 j in 0..8)
                {
                top[i, j] = (i32)(i + j);
                bottom[i, j] = (i32)(1000 + i);
                }
        }
    Stdio.printf("halves: t[5, 3] %d, t[40, 0] %d, sum %ld\n", t[5, 3], t[40, 0], total(t));

    // Each row from the next one: in one thread, top to bottom, every row
    // reads the next before it is written.
    tensor<i32, 2> next = t[1.., ..];
    par shift
        {
        for (u64 i in 0..63)
            for (u64 j in 0..8)
                t[i, j] = next[i, j] + 1;
        }
    Stdio.printf("shift: t[0, 3] %d, t[31, 7] %d, t[32, 0] %d, t[63, 0] %d\n", t[0, 3], t[31, 7], t[32, 0], t[63, 0]);

    // A column slice written at its own rows; a fresh tensor read anywhere.
    tensor<i32, 2> src = new tensor<i32, 2>(64, 2);
    for (u64 i = 0; i < 64; i++)
        {
        src[i, 0] = (i32)i;
        src[i, 1] = (i32)(2 * i);
        }
    tensor<i32, 2> cols = t[.., 2..4];
    par columns
        {
        for (u64 i in 0..64)
            for (u64 j in 0..2)
                cols[i, j] = src[63 - i, j];
        }
    Stdio.printf("columns: t[0, 2] %d, t[0, 3] %d, t[10, 2] %d, t[10, 4] %d\n", t[0, 2], t[0, 3], t[10, 2], t[10, 4]);
    return 0;
    }
