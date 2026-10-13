// par-reduce-lanes — a straight-line u32 reduce over the chunk range, the shape
// the GPU lane vectoriser accepts: a few integer ops on the item index, no
// memory, the reduction folded with +. Its Metal kernel is emitted as uint2
// lanes, so this fixture makes the ObjC printer (XTIRParMSL.m) and the port
// (Lower.xc) agree on the vectorised MSL under ir-diff.
#import "Stdio.xc"
#import "Par.xc"

#define N 2000

i32 main(void)
    {
    u32 total = 0;
    par mix :reduce(+ total)
        {
        for (u32 i in 0..N)
            {
            u32 x = i * 2654435761 + 0xd1b54a32;
            x = x ^ (x >> 15);
            x = x * 0x85ebca77;
            x = x ^ (x << 13);
            total = total + x;
            }
        }
    Stdio.printf("%u\n", total);
    return 0;
    }
