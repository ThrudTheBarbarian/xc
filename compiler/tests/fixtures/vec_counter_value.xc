// vec_counter_value.xc — a vectorised loop that reads its own counter as a
// value. Each lane of `p[i] = p[i] * K + i` needs its own i (i, i+1, i+2,
// ...): the counter is a header phi, which changes every trip, so it must
// not be broadcast as if it were loop-invariant. The xc compiler once did,
// and every lane of a vector added the first lane's i. Fixed and variable
// trip counts, trips that are not a multiple of the vector width, and the
// counter in a sum, a product and a xor; each loop's result against the
// same sum computed one element at a time.
#import "Stdio.xc"

#define N 1027

u32 mapAdd(u32* p, u32 n)
{
    for (u32 i in 0..n)
        p[i] = p[i] * (u32)2654435761 + i;
    u32 s = (u32)0;
    for (u32 i in 0..n)
        s = s ^ (p[i] + i * (u32)7);
    return s;
}

void mapMul(u32* p, u32 n)
{
    for (u32 i in 0..n)
        p[i] = p[i] + i * i;
}

void mapXor(i32* q, u32 n)
{
    for (u32 i in 0..n)
        q[i] = q[i] ^ (i32)i;
}

void mapFixed(u32* p)
{
    for (u32 i in 0..64)
        p[i] = p[i] + i;
}

i32 main(void)
{
    u32* p = new u32[N];
    i32* q = new i32[N];
    for (u32 i in 0..N)
    {
        p[i] = i * (u32)3;
        q[i] = (i32)i * -5;
    }
    Stdio.printf("mapAdd %u\n", mapAdd(p, (u32)N));
    Stdio.printf("mapAdd short %u\n", mapAdd(p, (u32)5));
    mapMul(p, (u32)N);
    mapXor(q, (u32)N - (u32)2);
    mapFixed(p);
    // The same checksums the slow way: one element, one step, no vectors.
    u32 sp = (u32)0;
    i32 sq = 0;
    for (u32 i in 0..N)
    {
        sp = sp * (u32)31 + p[i];
        sq = sq * 31 + q[i];
    }
    Stdio.printf("p %u\n", sp);
    Stdio.printf("q %d\n", sq);
    Stdio.printf("p[0..5] %u %u %u %u %u\n", p[0], p[1], p[2], p[3], p[4]);
    return 0;
}
