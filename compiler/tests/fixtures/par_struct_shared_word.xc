//xtc-warn: at an element another work item may write
// par_struct_shared_word.xc — two work items write different u8 fields of one
// element of an array of structs (item 2k writes pr[k].lo, item 2k+1 writes
// pr[k].hi). A kernel writes such a field together with the other bytes of
// its 32-bit word, so it would lose one of the two writes: the block runs on
// the CPU, says why, and gives the CPU's answer (tests/par/structs.sh).
//
//xtc-na: xt6502, m68k — par has no threads there
#import "Stdio.xc"
#import "Par.xc"

#define N 65536

struct Pair { u8 lo; u8 hi; u16 n; }

Pair pr[N / 2];

i32 main(void)
{
    for (u32 k in 0..N / 2)
        pr[k].n = (u16)k;
    par halves
    {
        for (u32 i in 0..N)
        {
            if ((i & (u32)1) == (u32)0)
                pr[i >> (u32)1].lo = (u8)(i % (u32)251);
            else
                pr[i >> (u32)1].hi = (u8)(i % (u32)241);
        }
    }
    u64 s = (u64)0;
    for (u32 k in 0..N / 2)
        s = s + (u64)pr[k].lo * (u64)3 + (u64)pr[k].hi * (u64)5 + (u64)pr[k].n;
    Stdio.printf("%lu\n", s);
    return 0;
}
