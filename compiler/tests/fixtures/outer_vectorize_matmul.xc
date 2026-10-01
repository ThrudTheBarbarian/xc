// outer_vectorize_matmul.xc — loops vectorised across the OUTER loop.
//
// `for j { s = 0; for k { s += f(k, j) } out[.. + j] = g(s) }` computes one
// cell per j, and four neighbouring cells are four lanes of a vector. Shapes:
//
//   T1  matrix multiply: a j-independent load (broadcast) times a load that
//       moves with j (a vector load), stored with an offset added
//   T2  the same over a different row stride, with the k loop counting to a
//       bound that is not the j bound
//   T3  a bitwise accumulation (xor) with a j-independent term mixed in
//   T4  the store target is ALSO read in the k loop — vectorising would read
//       cells before they are written, so the pass must decline and the scalar
//       answer must come out
//   T5  a j bound that does not divide by four — declined, still right
#import "Stdio.xc"

#define M 8

u32 sum(u32* c, u32 n)
    {
    u32 acc = (u32)0;
    for (u32 i = (u32)0; i < n; i++) acc = acc * (u32)31 + c[i];
    return acc;
    }

i32 main(void)
    {
    u32 a[M * M]; u32 b[M * M]; u32 c[M * M]; u32 d[M * 12];
    for (u32 i = (u32)0; i < (u32)(M * M); i++)
        { a[i] = (i * (u32)7 + (u32)3) & (u32)31; b[i] = (i * (u32)13 + (u32)5) & (u32)63; c[i] = (u32)0; }

    // T1
    for (u32 i = (u32)0; i < (u32)M; i++)
        for (u32 j = (u32)0; j < (u32)M; j++)
            {
            u32 s = (u32)0;
            for (u32 k = (u32)0; k < (u32)M; k++)
                s = s + (a[i * (u32)M + k] * b[k * (u32)M + j]);
            c[i * (u32)M + j] = s + i;
            }
    Stdio.printf("T1 %lu\n", sum(c, (u32)(M * M)));

    // T2: rows of 12 in d, k over 6
    for (u32 i = (u32)0; i < (u32)M; i++)
        for (u32 j = (u32)0; j < (u32)12; j++)
            {
            u32 s = (u32)1;
            for (u32 k = (u32)0; k < (u32)6; k++)
                s = s + (a[i * (u32)M + k] * b[k * (u32)M + (j & (u32)7)]);
            d[i * (u32)12 + j] = s;
            }
    Stdio.printf("T2 %lu\n", sum(d, (u32)(M * 12)));

    // T3
    for (u32 i = (u32)0; i < (u32)M; i++)
        for (u32 j = (u32)0; j < (u32)M; j++)
            {
            u32 s = i;
            for (u32 k = (u32)0; k < (u32)M; k++)
                s = s ^ (b[k * (u32)M + j] + a[k]);
            c[i * (u32)M + j] = s;
            }
    Stdio.printf("T3 %lu\n", sum(c, (u32)(M * M)));

    // T4: c is both read and written
    for (u32 j = (u32)0; j < (u32)M; j++)
        {
        u32 s = (u32)0;
        for (u32 k = (u32)0; k < (u32)M; k++)
            s = s + c[k * (u32)M + j] + c[j];
        c[j] = s;
        }
    Stdio.printf("T4 %lu\n", sum(c, (u32)(M * M)));

    // T5: j to 6
    for (u32 i = (u32)0; i < (u32)M; i++)
        for (u32 j = (u32)0; j < (u32)6; j++)
            {
            u32 s = (u32)0;
            for (u32 k = (u32)0; k < (u32)M; k++)
                s = s + (a[i * (u32)M + k] * b[k * (u32)M + j]);
            c[i * (u32)M + j] = s;
            }
    Stdio.printf("T5 %lu\n", sum(c, (u32)(M * M)));
    return (i32)0;
    }
