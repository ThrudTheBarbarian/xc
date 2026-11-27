// A loop calling a method on a receiver it does not change, behind a null
// test (`p != null && p.count() > q ? …`), with the receiver null on one
// pass. The devirtualiser versions such a loop on the receiver's class; it
// read the class before the loop, ahead of the loop's own null test, so a
// null receiver crashed at -O2 and -O3.
#import "Foundation.xc"

class Boxv : Object
    {
    u32 n;
    u32 count(void) { return n; }
    u32 at(u32 i) { return i * (u32)2; }
    }

class Box2v : Boxv
    {
    u32 count(void) { return n + (u32)1; }
    }

Boxv* lookup(Map* m, u8* k)
    {
    return (Boxv*)m.get((Hashable*)String.withCString(k));
    }

i32 main(void)
    {
    Map* m = new Map();
    Boxv* b = new Boxv();
    b.n = (u32)3;
    m.set((Hashable*)String.withCString("b"), (Object*)b);
    u32 tot = (u32)0;
    u8* keys[2];
    keys[0] = "b";
    keys[1] = "none";
    for (u32 k = (u32)0; k < (u32)2; k = k + (u32)1)
        {
        Boxv* was = lookup(m, keys[k]);
        for (u32 q = (u32)0; q < (u32)4; q = q + (u32)1)
            tot = tot + (was != (Boxv*)0 && was.count() > q ? was.at(q) : (u32)100);
        }
    Stdio.printf("tot %u\n", tot);
    return 0;
    }
