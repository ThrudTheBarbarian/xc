// par_vulkan_inputs.xc — a par block run ten times over a 16 MB table it only
// reads, writing a second array whole (#15). On a Vulkan device the table is
// sent once and not again while the host leaves it alone; a host write to it
// between runs is seen by the next run. The argument count picks the case: 1
// no access between runs, 2 a write to the table. Every case prints the same
// sums on any device (tests/par/vulkan-inputs.sh).
//
//xtc-na: xt6502, m68k — par has no threads there
#import "Stdio.xc"
#import "Par.xc"

#define N 4194304

i32 main(i32 argc, u8** argv)
{
    u32* tab = new u32[N];
    u32* out = new u32[N];
    for (u32 i in 0..N) tab[i] = (i * (u32)2654435761) >> (u32)7;
    u32 seen = (u32)0;
    for (u32 r in 0..10)
    {
        u32 k = r + (u32)1;
        par step
        {
            for (u32 i in 0..N)
                out[i] = tab[i] * k + i;
        }
        seen = seen + out[(u32)5 + r];
        if (argc == 2)
            tab[(u32)5 + r] = tab[(u32)5 + r] + (u32)7;
    }
    u32 sum = (u32)0;
    for (u32 i in 0..N) sum = sum + out[i];
    Stdio.printf("%u %u\n", sum, seen);
    return 0;
}
