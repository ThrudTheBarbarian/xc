// Array.sortUsing over the inputs that break a naive quicksort: already in
// order, reversed, all equal, few distinct values, an organ pipe and random,
// at sizes either side of the insertion-sort cutoff. Each result must be in
// order and hold the same values (count and sum). The Lomuto sort with the
// last cell as pivot went quadratic, and as deep as the array is long, on the
// in-order case; an object's symbol names spent most of a -c build there.
#import "Stdio.xc"
#import "Foundation.xc"

i8 byValue(Object* a, Object* b)
    {
    u32 x = ((Number*)a).asU32();
    u32 y = ((Number*)b).asU32();
    if (x < y)
        return (i8)-1;
    if (x > y)
        return (i8)1;
    return (i8)0;
    }

u32 seed;

u32 next(void)
    {
    seed = seed * (u32)1103515245 + (u32)12345;
    return (seed >> (u32)8) & (u32)$FFFF;
    }

u32 make(u32 shape, u32 i, u32 n)
    {
    if (shape == (u32)0) return i;                       // in order
    if (shape == (u32)1) return n - i;                   // reversed
    if (shape == (u32)2) return (u32)7;                  // all equal
    if (shape == (u32)3) return next() % (u32)3;         // few distinct
    if (shape == (u32)4) return i < n / (u32)2 ? i : n - i;  // organ pipe
    return next();                                       // random
    }

i32 main(void)
    {
    u32 sizes[6];
    sizes[0] = (u32)0; sizes[1] = (u32)1; sizes[2] = (u32)2;
    sizes[3] = (u32)15; sizes[4] = (u32)17; sizes[5] = (u32)5000;
    u32 bad = (u32)0;
    u32 runs = (u32)0;
    seed = (u32)1;
    for (u32 shape in 0..6)
        for (u32 si in 0..6)
            {
            u32 n = sizes[si];
            Array* a = new Array();
            u32 sum = (u32)0;
            for (u32 i = (u32)0; i < n; i++)
                {
                u32 v = make(shape, i, n);
                sum = sum + v;
                a.add((Object*)Number.withU32(v));
                }
            a.sortUsing(&byValue);
            u32 got = (u32)0;
            bool inOrder = true;
            for (u32 i = (u32)0; i < a.count(); i++)
                {
                u32 v = ((Number*)a.get(i)).asU32();
                got = got + v;
                if (i > (u32)0 && ((Number*)a.get(i - (u32)1)).asU32() > v)
                    inOrder = false;
                }
            if (!inOrder || got != sum || a.count() != n)
                {
                Stdio.printf("shape %u size %u: wrong\n", shape, n);
                bad++;
                }
            runs++;
            }
    Stdio.printf("%u sorts, %u wrong\n", runs, bad);
    return 0;
    }
