// f4_atomic.xc — f4StoreAtomic (Fp4.xc) under contention: four threads each
// write their own element of one f4 array, the four elements in two bytes,
// many times, and read it back after each store. A plain `a[i] = v` rewrites
// the whole byte, so a thread could put back a stale copy of its neighbour's
// element; the atomic store swaps in only its own nibble, so no read-back
// ever differs. Not on xt6502 or m68k, which have no threads.
//xtc-flags: target=arm64
//xtc-na: xt6502, m68k — no threads there
#define ENABLE_64BIT 1
#import "Stdio.xc"
#import "Foundation.xc"
#import "Thread.xc"
#import "Fp4.xc"

f4 shared[4];

class Hammer
{
    u32 slot;
    u32 lost;

    void go(void)
    {
        for (u32 r = 0; r < 200000; r++)
            {
            f4 v = (f4)(f32)((r + slot) % 7);
            f4StoreAtomic(shared, (u64)slot, v);
            if (shared[slot] != v)
                lost++;
            }
    }
}

i32 main(void)
{
    Array* hs = new Array();
    Array* ts = new Array();
    for (u32 s = 0; s < 4; s++)
        {
        Hammer* h = new Hammer();
        h.slot = s;
        hs.add((Object*)h);
        ts.add((Object*)Thread.spawn(&h.go));
        }
    u32 lost = 0;
    for (u32 s = 0; s < 4; s++)
        {
        ((Thread*)ts.get(s)).join();
        lost = lost + ((Hammer*)hs.get(s)).lost;
        }
    Stdio.printf("lost %d\n", (i16)lost);
    for (u32 s = 0; s < 4; s++)
        Stdio.printf("%f ", shared[s]);
    Stdio.printf("\n");
    return 0;
}
