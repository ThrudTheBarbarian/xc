// Loop variables that rotate or swap: each loop's phi copies on the back edge
// form a cycle, which needs a temporary. Long cycles, wide values, aggregates
// and several cycles on one edge each once came out wrong on some back end.

typedef struct {
    i32 x;
    i32 y;
} Pair;

typedef struct {
    i32 a;
    i16 b;
    u8 c;
} Odd;

i32 rot4(i32 n)
    {
    i32 a = 0;
    i32 b = 1;
    i32 c = 2;
    i32 d = 3;
    for (i32 i = 0; i < n; i = i + 1)
        {
        i32 t = a;
        a = b;
        b = c;
        c = d;
        d = t;
        }
    return ((a * 8 + b) * 8 + c) * 8 + d;
    }

i32 rot8(i32 n)
    {
    i32 a = 0;
    i32 b = 1;
    i32 c = 2;
    i32 d = 3;
    i32 e = 4;
    i32 f = 5;
    i32 g = 6;
    i32 h = 7;
    for (i32 i = 0; i < n; i = i + 1)
        {
        i32 t = a;
        a = b;
        b = c;
        c = d;
        d = e;
        e = f;
        f = g;
        g = h;
        h = t;
        }
    return ((((((a * 8 + b) * 8 + c) * 8 + d) * 8 + e) * 8 + f) * 8 + g) * 8 + h;
    }

double rotd(i32 n)
    {
    double a = 0.0;
    double b = 1.0;
    double c = 2.0;
    double d = 3.0;
    double e = 4.0;
    for (i32 i = 0; i < n; i = i + 1)
        {
        double t = a;
        a = b;
        b = c;
        c = d;
        d = e;
        e = t;
        }
    return (((a * 8.0 + b) * 8.0 + c) * 8.0 + d) * 8.0 + e;
    }

i64 swap64(i32 n)
    {
    i64 a = 1;
    i64 b = 2;
    for (i32 i = 0; i < n; i = i + 1)
        {
        i64 t = a;
        a = b;
        b = t;
        }
    return a * 10 + b;
    }

// Two disjoint swaps and a chain on one edge.
i32 twoSwaps(i32 n)
    {
    i32 a = 1;
    i32 b = 2;
    i32 c = 3;
    i32 d = 4;
    i32 e = 5;
    for (i32 i = 0; i < n; i = i + 1)
        {
        e = a;
        i32 t = a;
        a = b;
        b = t;
        i32 u = c;
        c = d;
        d = u;
        }
    return (((a * 8 + b) * 8 + c) * 8 + d) * 8 + e;
    }

i32 swapPair(i32 n)
    {
    Pair p = {1, 2};
    Pair q = {3, 4};
    for (i32 i = 0; i < n; i = i + 1)
        {
        Pair t = p;
        p = q;
        q = t;
        }
    return p.x * 1000 + p.y * 100 + q.x * 10 + q.y;
    }

i32 rotOdd(i32 n)
    {
    Odd p = {1, 2, 3};
    Odd q = {4, 5, 6};
    Odd r = {7, 8, 9};
    for (i32 i = 0; i < n; i = i + 1)
        {
        Odd t = p;
        p = q;
        q = r;
        r = t;
        }
    return ((p.a * 10 + (i32)p.b) * 10 + (i32)p.c) * 1000
         + ((q.a * 10 + (i32)q.b) * 10 + (i32)q.c);
    }

i32 main(void)
    {
    for (i32 n = 1; n <= 3; n = n + 1)
        {
        Stdio.printf("n=%d rot4=%d rot8=%d rotd=%d swap64=%d\n",
                     n, rot4(n), rot8(n), (i32)rotd(n), (i32)swap64(n));
        Stdio.printf("n=%d twoSwaps=%d swapPair=%d rotOdd=%d\n",
                     n, twoSwaps(n), swapPair(n), rotOdd(n));
        }
    return 0;
    }
