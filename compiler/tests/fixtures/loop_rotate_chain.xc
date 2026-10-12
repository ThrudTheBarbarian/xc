// Loops whose test is a short-circuit chain, `while (a && b)`. Rotation copies
// the whole chain to the bottom of the body, and the body may read values the
// chain computed (the loaded `a[j-1]`, and `j-1` as the next `j`), so these
// check each shape against the unrotated answer: a value read after the loop,
// a body that branches, a loop that exits at each test before its first
// iteration, and a chain of three tests.
//xtc-na: xt6502 — loop rotation is off on the 6502, and the 32-bit checksums need %u at full width
#use Stdio

#define N 40

u32 sortU(u32 seed)
    {
    u32 a[N];
    for (u32 i = (u32)0; i < (u32)N; i++)
        a[i] = ((i * (u32)2654435761) ^ seed) % (u32)1000;
    for (u32 i = (u32)1; i < (u32)N; i++)
        {
        u32 v = a[i];
        u32 j = i;
        while (j > (u32)0 && a[j - (u32)1] > v)
            {
            a[j] = a[j - (u32)1];
            j = j - (u32)1;
            }
        a[j] = v;
        }
    u32 bad = (u32)0;
    for (u32 i = (u32)1; i < (u32)N; i++)
        if (a[i - (u32)1] > a[i])
            bad++;
    return a[0] * (u32)1000000 + a[N - 1] * (u32)1000 + bad;
    }

i32 sortI(i32 seed)
    {
    i32 b[N];
    for (i32 i = 0; i < N; i++)
        b[i] = ((i * 7919 + seed) % 201) - 100;
    for (i32 i = 1; i < N; i++)
        {
        i32 key = b[i];
        i32 j = i - 1;
        while (j >= 0 && b[j] > key)
            {
            b[j + 1] = b[j];
            j = j - 1;
            }
        b[j + 1] = key;
        }
    i32 bad = 0;
    for (i32 i = 1; i < N; i++)
        if (b[i - 1] > b[i])
            bad++;
    return b[0] * 1000 + b[N - 1] + bad * 1000000;
    }

// Three tests, and the index read after the loop.
u32 scan3(u32* a, u32 n, u32 limit, u32* where)
    {
    u32 i = (u32)0;
    u32 s = (u32)0;
    while (i < n && a[i] != (u32)0 && a[i] < limit)
        {
        s = s + a[i] * (i + (u32)1);
        i++;
        }
    *where = i;
    return s;
    }

// A body that branches, reading the chain's load.
i32 branchy(i32* a, i32 n)
    {
    i32 i = 0;
    i32 odd = 0;
    i32 even = 0;
    while (i < n && a[i] > -50)
        {
        i32 x = a[i];
        if ((x & 1) != 0)
            odd = odd + x;
        else
            even = even - x;
        i = i + 1;
        }
    return odd * 10000 + even * 10 + i;
    }

i32 main(void)
    {
    Stdio.printf("sortU %u %u\n", sortU((u32)1), sortU((u32)987654321));
    Stdio.printf("sortI %d %d\n", sortI(3), sortI(-77));

    u32 a[10];
    for (u32 i = (u32)0; i < (u32)10; i++)
        a[i] = i * (u32)3 + (u32)1;
    u32 w = (u32)99;
    u32 s = scan3(&a[0], (u32)10, (u32)1000, &w);
    Stdio.printf("scan3 all %u %u\n", s, w);
    s = scan3(&a[0], (u32)10, (u32)14, &w);
    Stdio.printf("scan3 limit %u %u\n", s, w);
    a[6] = (u32)0;
    s = scan3(&a[0], (u32)10, (u32)1000, &w);
    Stdio.printf("scan3 zero %u %u\n", s, w);
    s = scan3(&a[0], (u32)0, (u32)1000, &w);
    Stdio.printf("scan3 empty %u %u\n", s, w);
    s = scan3(&a[0], (u32)10, (u32)1, &w);
    Stdio.printf("scan3 first %u %u\n", s, w);
    a[0] = (u32)0;
    s = scan3(&a[0], (u32)10, (u32)1000, &w);
    Stdio.printf("scan3 second %u %u\n", s, w);

    i32 b[12];
    for (i32 i = 0; i < 12; i++)
        b[i] = i * 5 - 3;
    Stdio.printf("branchy %d\n", branchy(&b[0], 12));
    b[7] = -60;
    Stdio.printf("branchy stop %d\n", branchy(&b[0], 12));
    b[0] = -60;
    Stdio.printf("branchy none %d\n", branchy(&b[0], 12));
    return 0;
    }
