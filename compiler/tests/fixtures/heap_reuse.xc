//xtc-na: xt6502 — a 64 KB block does not fit the 6502 heap
// A freed block must be reusable: 300 objects of 64 KB each, one live at a
// time, is 19 MB in total but never more than 64 KB at once. Guards the m68k
// simulator's GEMDOS Mfree, which once did nothing, so a program that churned
// through more than its TPA ran out of memory (bug 527).
#import "Stdio.xc"

class Slab
    {
    u32* words;

    void init(void)
        {
        words = new u32[16384];
        }

    void dealloc(void)
        {
        delete words;
        }
    }

i32 main(void)
{
    u32 sum = (u32)0;
    for (u32 i = (u32)0; i < (u32)300; i = i + (u32)1)
        {
        Slab* s = new Slab();
        if (s.words == (u32*)0)
            {
            Stdio.printf("allocation %lu failed\n", i);
            return 1;
            }
        s.words[0] = i;
        s.words[16383] = i + (u32)1;
        sum = sum + s.words[0] + s.words[16383];
        }
    Stdio.printf("sum %lu\n", sum);
    return 0;
}
