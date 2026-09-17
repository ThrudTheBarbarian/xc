// mem_copy — copy between arrays element by element.
// Exercises: load/store pairing, the memcpy idiom, pointer induction.
#import "Stdio.xc"
#define N 4096
i32 main(i32 argc, u8** argv)
    {
    u32 src[N]; u32 dst[N];
    u32 seed = (u32)argc;
    for (u32 i = (u32)0; i < (u32)N; i++) src[i] = i + seed;
    u32 acc = (u32)0;
    for (u32 r = (u32)0; r < (u32)20000; r++)
        {
        for (u32 i = (u32)0; i < (u32)N; i++) dst[i] = src[i] + r;
        acc = acc + dst[r % (u32)N];
        }
    Stdio.printf("%lu\n", acc);
    return 0;
    }
