// A bare call to a method of the same class, inside loops --par-style=auto
// would lift: a for loop stepped by a plain literal (u32 and i32 counters),
// a nested pair, and a counted while loop. Each means self.m(…), which a par
// block cannot make, so each loop stays a loop and calls the method (#431).
i32 printf(u8* f, ...);

class Probe : Object
    {
    u32 base;

    u32 twice(u32 v)
        {
        return v * 2 + base;
        }

    u32 forU32(u32 n)
        {
        u32 s = 0;
        for (u32 k = 0; k < n; k = k + 1)
            {
            s = s + twice(k);
            }
        return s;
        }

    i32 forI32(i32 n)
        {
        i32 s = 0;
        for (i32 k = 0; k < n; k = k + 1)
            {
            s = s + negate(k);
            }
        return s;
        }

    u32 nested(u32 n)
        {
        u32 s = 0;
        for (u32 i = 0; i < n; i = i + 1)
            {
            for (u32 j = 0; j < n; j = j + 1)
                {
                s = s + twice(i * n + j);
                }
            }
        return s;
        }

    u32 counted(u32 n)
        {
        u32 s = 0;
        u32 k = 0;
        while (k < n)
            {
            s = s + later(k);
            k = k + 1;
            }
        return s;
        }

    i32 negate(i32 v)
        {
        return 0 - v;
        }

    u32 later(u32 v)
        {
        return v + 100;
        }
    }

i32 main()
    {
    Probe* p = new Probe();
    printf("%u\n", p.forU32(4));
    printf("%d\n", p.forI32(5));
    printf("%u\n", p.nested(3));
    printf("%u\n", p.counted(4));
    p.base = 1;
    printf("%u\n", p.forU32(4));
    return 0;
    }
