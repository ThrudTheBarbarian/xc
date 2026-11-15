// par_resident.xc — a par block run ten times over an array it reads and
// writes (#15). With XC_PAR_RESIDENT=1 on a CUDA device the array stays on
// the card between runs and comes back once, when the host reads it; a host
// read between runs fetches it each time, and a host write between runs is
// seen by the next run. The argument count picks the case: 1 no access
// between runs, 2 a read, 3 a write. Every case prints the same sums with
// and without residency, on any device (tests/par/resident.sh).
//
//xtc-na: xt6502, m68k — par has no threads there
#import "Stdio.xc"
#import "Par.xc"

#define N 4194304

i32 main(i32 argc, u8** argv)
{
    u32* acc = new u32[N];
    for (u32 i in 0..N) acc[i] = i & (u32)1023;
    u32 seen = (u32)0;
    for (u32 r in 0..10)
    {
        par step
        {
            for (u32 i in 0..N)
                acc[i] = acc[i] * (u32)3 + i;
        }
        if (argc == 2)
            seen = seen + acc[(u32)5 + r];
        if (argc == 3)
            acc[r] = acc[r] + (u32)7;
    }
    u32 last = acc[N - 1];
    u32 sum = (u32)0;
    for (u32 i in 0..N) sum = sum + acc[i];
    Stdio.printf("%u %u %u\n", sum, seen, last);
    return 0;
}
