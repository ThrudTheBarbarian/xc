// tensor_basic.xc — tensor<T, R> values: ranks 1, 2, 3 and 8; f32, f64,
// i32, u8, f16, bf16, f8 and f4 elements. A new tensor is zero-filled; every
// element of a small tensor is written and read back; shape, stride, rank,
// count and isContiguous; a copy shares the storage (a write through one is
// read through the other); passing and returning; a field of a class;
// compound assignment; an f4 element written leaves its neighbours alone.
//xtc-na: xt6502 — a tensor value is wider than the 16 bytes it returns by value
#import "Stdio.xc"

class Holder
    {
    tensor<f32, 1> w;
    i32 n;
    }

tensor<i32, 2> grid(u64 r, u64 c)
    {
    tensor<i32, 2> g = new tensor<i32, 2>(r, c);
    for (u64 i = 0; i < r; i++)
        for (u64 j = 0; j < c; j++)
            g[i, j] = (i32)(i * 10 + j);
    return g;
    }

void bump(tensor<i32, 2> g)
    {
    g[0, 0] = g[0, 0] + 100;
    }

i32 sum2(tensor<i32, 2> g)
    {
    i32 s = 0;
    for (u64 i = 0; i < g.shape(0); i++)
        for (u64 j = 0; j < g.shape(1); j++)
            s = s + g[i, j];
    return s;
    }

i32 main(void)
    {
    // Rank 1, f32: zero-filled, then each element.
    tensor<f32, 1> a = new tensor<f32, 1>(5);
    f32 z = 0.0;
    for (u64 i = 0; i < 5; i++)
        z = z + a[i];
    for (u64 i = 0; i < 5; i++)
        a[i] = (f32)i * 1.5;
    Stdio.printf("f32 zero %d a4 %d\n", (i16)z, (i16)(a[4] * 2.0));

    // Rank 2, i32: members.
    tensor<i32, 2> g = grid(3, 4);
    Stdio.printf("i32 %d %d sum %d\n", (i16)g[2, 3], (i16)g[1, 0], (i16)sum2(g));
    Stdio.printf("rank %d count %d\n", (i16)g.rank, (i16)g.count);
    Stdio.printf("shape %d %d\n", (i16)g.shape(0), (i16)g.shape(1));
    Stdio.printf("stride %d %d\n", (i16)g.stride(0), (i16)g.stride(1));
    Stdio.printf("contig %d\n", g.isContiguous ? 1 : 0);

    // A copy shares the storage; a parameter too.
    tensor<i32, 2> h = g;
    h[0, 1] = 77;
    bump(h);
    Stdio.printf("shared %d %d\n", (i16)g[0, 1], (i16)g[0, 0]);

    // Compound assignment.
    g[1, 1] += 5;
    g[1, 1] *= 2;
    g[2, 2] -= 22;
    Stdio.printf("compound %d %d\n", (i16)g[1, 1], (i16)g[2, 2]);

    // Rank 3, u8.
    tensor<u8, 3> c = new tensor<u8, 3>(2, 3, 4);
    u16 cs = 0;
    for (u64 i = 0; i < 2; i++)
        for (u64 j = 0; j < 3; j++)
            for (u64 k = 0; k < 4; k++)
                c[i, j, k] = (u8)(i * 12 + j * 4 + k);
    for (u64 i = 0; i < 2; i++)
        for (u64 j = 0; j < 3; j++)
            for (u64 k = 0; k < 4; k++)
                cs = cs + (u16)c[i, j, k];
    Stdio.printf("u8 %d %d st %d\n", (i16)c[1, 2, 3], (i16)cs, (i16)c.stride(0));

    // Rank 8, f64.
    tensor<f64, 8> e = new tensor<f64, 8>(2, 1, 2, 1, 2, 1, 2, 1);
    e[1, 0, 1, 0, 1, 0, 1, 0] = 2.5;
    e[0, 0, 0, 0, 0, 0, 1, 0] = 1.0;
    f64* ep = e.data();
    Stdio.printf("f64 n %d r %d\n", (i16)e.count, (i16)e.rank);
    Stdio.printf("f64 %d %d\n", (i16)(ep[15] * 2.0), (i16)ep[1]);
    Stdio.printf("f64 st %d %d\n", (i16)e.stride(0), (i16)e.stride(6));

    // The small floats.
    tensor<f16, 2> hf = new tensor<f16, 2>(2, 3);
    tensor<bf16, 2> bf = new tensor<bf16, 2>(2, 3);
    tensor<f8, 2> ef = new tensor<f8, 2>(2, 3);
    for (u64 i = 0; i < 2; i++)
        for (u64 j = 0; j < 3; j++)
            {
            hf[i, j] = (f16)((f32)(i * 3 + j) * 0.5);
            bf[i, j] = (bf16)((f32)(i * 3 + j) * 0.25);
            ef[i, j] = (f8)((f32)(i * 3 + j));
            }
    f32 hs = 0.0;
    for (u64 i = 0; i < 2; i++)
        for (u64 j = 0; j < 3; j++)
            hs = hs + (f32)hf[i, j] + (f32)bf[i, j] + (f32)ef[i, j];
    Stdio.printf("packs %d\n", (i16)(hs * 4.0));
    hf[1, 2] += (f16)1.0;
    Stdio.printf("f16 %d\n", (i16)((f32)hf[1, 2] * 2.0));

    // f4: two to a byte; a write leaves its neighbours untouched.
    tensor<f4, 1> q = new tensor<f4, 1>(5);
    q[2] = (f4)1.5;
    Stdio.printf("f4 %d %d %d\n", (i16)((f32)q[1] * 2.0), (i16)((f32)q[2] * 2.0), (i16)((f32)q[3] * 2.0));
    q[1] = (f4)-3.0;
    q[3] = (f4)6.0;
    u8* qb = q.bytes();
    Stdio.printf("f4 bytes %x %x %x\n", (u16)qb[0], (u16)qb[1], (u16)qb[2]);

    // A literal takes the element's type.
    q[4] = 3.0;
    hf[0, 0] = 0.75;
    ef[0, 0] = 12.0;
    Stdio.printf("lit %d %d %d\n", (i16)((f32)q[4] * 2.0), (i16)((f32)hf[0, 0] * 4.0), (i16)(f32)ef[0, 0]);

    // A field of a class.
    Holder* o = new Holder();
    o.w = a;
    o.w[0] = 9.0;
    Stdio.printf("field %d %d\n", (i16)a[0], (i16)o.w.count);
    return 0;
    }
