// par_gpu_resident.xc — a small table a par block only reads stays on the
// device between runs while it is unchanged. The host changing it between
// runs, and another block using the same device slot in between, must both
// be seen: every sum is the CPU's.
#import "Stdio.xc"
#import "Par.xc"
u32 tableA[1024];
u32 tableB[1024];
u32 sum(u32 which)
    {
    u32 t = (u32)0;
    if (which == (u32)0)
        {
        par :reduce(+ t)
            {
            for (u32 i in 0..1024)
                t = t + tableA[i];
            }
        }
    else
        {
        par :reduce(+ t)
            {
            for (u32 i in 0..1024)
                t = t + tableB[i];
            }
        }
    return t;
    }
i32 main(i32 argc, u8** argv)
    {
    for (u32 i in 0..1024) { tableA[i] = i; tableB[i] = (u32)7; }
    u32 a1 = sum((u32)0);
    tableA[5] = (u32)1000;           // the host changes a read-only table between runs
    u32 a2 = sum((u32)0);
    u32 b1 = sum((u32)1);            // another block, maybe the same device slot
    u32 a3 = sum((u32)0);            // back to the first: must not see tableB
    tableA[1023] = (u32)0;
    u32 a4 = sum((u32)0);
    Stdio.printf("%u %u %u %u %u\n", a1, a2, b1, a3, a4);
    return 0;
    }
