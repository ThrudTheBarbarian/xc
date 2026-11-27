// tensor_view_classes.xc — views whose classes the unit first meets as the
// results of other tensor classes' methods: a rank-3 tensor is written before
// any rank-1 or rank-2 one, so its slices return classes laid out after it.
// Each view must come back by value, its header and storage intact after the
// method's frame is gone and the stack is reused.
//xtc-na: xt6502 — a tensor value is wider than the 16 bytes it returns by value
#import "Stdio.xc"

// A rank-3 tensor of i*100 + j*10 + k.
tensor<i32, 3> cube(u64 n0, u64 n1, u64 n2)
    {
    tensor<i32, 3> c = new tensor<i32, 3>(n0, n1, n2);
    for (u64 i = 0; i < n0; i++)
        for (u64 j = 0; j < n1; j++)
            for (u64 k = 0; k < n2; k++)
                c[i, j, k] = (i32)(i * 100 + j * 10 + k);
    return c;
    }

// Writes over the stack below its caller's frame.
i64 clobber(i64 n)
    {
    i64[64] junk;
    for (i64 i = 0; i < 64; i++)
        junk[i] = n + i;
    i64 s = 0;
    for (i64 i = 0; i < 64; i++)
        s += junk[i];
    return s;
    }

// A row of a cube that dies here: the view holds the storage.
tensor<i32, 1> row(u64 i, u64 j)
    {
    tensor<i32, 3> c = cube(2, 3, 4);
    return c[i, j, ..];
    }

// A plane of a cube that dies here.
tensor<i32, 2> plane(u64 k)
    {
    tensor<i32, 3> c = cube(2, 3, 4);
    return c[.., .., k];
    }

i32 sum1(tensor<i32, 1> t)
    {
    clobber(5);
    i32 s = 0;
    for (u64 i = 0; i < t.shape(0); i++)
        s += t[i];
    return s;
    }

i32 main(void)
    {
    tensor<i32, 3> c = cube(2, 3, 4);

    // Temporaries: each slice is read as soon as it returns.
    Stdio.printf("c[1, 2, ..][3] %d\n", c[1, 2, ..][3]);
    Stdio.printf("c[1, .., 2] shape %d stride %d offset %d\n", (i32)c[1, .., 2].shape(0), (i32)c[1, .., 2].stride(0),
                 (i32)c[1, .., 2].offset());
    Stdio.printf("c[.., 1, ..][1, 2] %d\n", c[.., 1, ..][1, 2]);

    // Passed on: the callee reuses the stack the method used.
    Stdio.printf("sum1(c[0, 1, ..]) %d\n", sum1(c[0, 1, ..]));
    Stdio.printf("sum1(c[1, .., 3]) %d\n", sum1(c[1, .., 3]));

    // Held after the stack is reused.
    tensor<i32, 1> r = c[1, 1, ..];
    tensor<i32, 2> p = c[0, .., ..];
    clobber(9);
    Stdio.printf("r offset %d shape %d stride %d:", (i32)r.offset(), (i32)r.shape(0), (i32)r.stride(0));
    for (u64 i = 0; i < r.shape(0); i++)
        Stdio.printf(" %d", r[i]);
    Stdio.printf("\n");
    Stdio.printf("p shape %d %d stride %d %d: %d %d\n", (i32)p.shape(0), (i32)p.shape(1), (i32)p.stride(0),
                 (i32)p.stride(1), p[1, 2], p[2, 3]);

    // Views of cubes that died in the functions that made them.
    tensor<i32, 1> q = row(1, 2);
    tensor<i32, 2> pl = plane(3);
    clobber(11);
    Stdio.printf("row(1, 2): %d %d %d %d\n", q[0], q[1], q[2], q[3]);
    Stdio.printf("plane(3) shape %d %d: %d %d %d\n", (i32)pl.shape(0), (i32)pl.shape(1), pl[0, 0], pl[1, 1], pl[1, 2]);

    // A slice of a returned slice.
    Stdio.printf("plane(1)[1, ..][2] %d\n", plane(1)[1, ..][2]);
    return 0;
    }
