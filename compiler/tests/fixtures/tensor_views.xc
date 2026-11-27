// tensor_views.xc — views of a tensor's storage, none of them a copy:
// slices of ranks 1, 2 and 3 with every bound form (a..b, a...b, a.., ..b,
// ...b, ..), an index that drops a dimension, a slice of a slice (one header:
// the offsets add and the strides stay), transpose and permute, a slice of a
// transposed slice, broadcast reads (stride 0), writes through a slice seen
// through the base, view of a contiguous tensor, reshape copying a transposed
// one, copy(), f4 slices at odd offsets read and written, and the storage
// freed only when the last view of it goes.
//xtc-na: xt6502 — a tensor value is wider than the 16 bytes it returns by value
#import "Stdio.xc"

void show1(u8* what, tensor<i32, 1> t)
    {
    Stdio.printf("%s: offset %d shape %d stride %d\n", what, (i32)t.offset(), (i32)t.shape(0), (i32)t.stride(0));
    }

void show2(u8* what, tensor<i32, 2> t)
    {
    Stdio.printf("%s: offset %d shape %d %d stride %d %d\n", what, (i32)t.offset(), (i32)t.shape(0), (i32)t.shape(1),
                 (i32)t.stride(0), (i32)t.stride(1));
    }

void show3(u8* what, tensor<i32, 3> t)
    {
    Stdio.printf("%s: offset %d shape %d %d %d stride %d %d %d\n", what, (i32)t.offset(), (i32)t.shape(0),
                 (i32)t.shape(1), (i32)t.shape(2), (i32)t.stride(0), (i32)t.stride(1), (i32)t.stride(2));
    }

// Every element of a rank-2 view, row by row.
void dump2(tensor<i32, 2> t)
    {
    for (u64 i = 0; i < t.shape(0); i++)
        {
        for (u64 j = 0; j < t.shape(1); j++)
            Stdio.printf(" %d", t[i, j]);
        Stdio.printf(" |");
        }
    Stdio.printf("\n");
    }

// A view made in a function and returned: the storage goes with it.
tensor<i32, 1> middle(tensor<i32, 1> t)
    {
    return t[1..t.shape(0) - 1];
    }

i32 main(void)
    {
    // Rank 1: every bound form.
    tensor<i32, 1> a = new tensor<i32, 1>(10);
    for (u64 i = 0; i < 10; i++)
        a[i] = (i32)(i * 10);
    show1("a[2..5]", a[2..5]);
    show1("a[2...5]", a[2...5]);
    show1("a[7..]", a[7..]);
    show1("a[..3]", a[..3]);
    show1("a[...3]", a[...3]);
    show1("a[..]", a[..]);
    tensor<i32, 1> s = a[2..8];
    Stdio.printf("a[2..8][1] %d, [5] %d\n", s[1], s[5]);

    // Rank 2 and 3: ranges, open ranges and dropped dimensions mixed.
    tensor<i32, 3> c = new tensor<i32, 3>(2, 3, 4);
    for (u64 i = 0; i < 2; i++)
        for (u64 j = 0; j < 3; j++)
            for (u64 k = 0; k < 4; k++)
                c[i, j, k] = (i32)(i * 100 + j * 10 + k);
    show3("c", c);
    show3("c[.., 1.., 1...2]", c[.., 1.., 1...2]);
    tensor<i32, 2> p = c[1, .., 1..3];
    show2("c[1, .., 1..3]", p);
    dump2(p);
    tensor<i32, 1> row = c[0, 2, ..];
    show1("c[0, 2, ..]", row);
    tensor<i32, 1> col = c[1, .., 3];
    show1("c[1, .., 3]", col);
    Stdio.printf("col %d %d %d\n", col[0], col[1], col[2]);

    // A slice of a slice is one header over the same storage.
    tensor<i32, 2> pp = p[1.., ..1];
    show2("c[1, .., 1..3][1.., ..1]", pp);
    dump2(pp);

    // Transpose and permute reorder the shapes and strides.
    tensor<i32, 2> m = c[0, .., ..];
    tensor<i32, 2> mt = m.transpose();
    show2("m.transpose()", mt);
    dump2(mt);
    tensor<i32, 3> cp = c.permute(2, 0, 1);
    show3("c.permute(2, 0, 1)", cp);
    Stdio.printf("cp[3, 1, 2] %d, c[1, 2, 3] %d\n", cp[3, 1, 2], c[1, 2, 3]);
    tensor<i32, 2> mts = mt[1..3, 1..];
    show2("m.transpose()[1..3, 1..]", mts);
    dump2(mts);
    Stdio.printf("contiguous: c %d, m %d, mt %d, p %d\n", c.isContiguous ? 1 : 0, m.isContiguous ? 1 : 0,
                 mt.isContiguous ? 1 : 0, p.isContiguous ? 1 : 0);

    // Broadcast: a dimension of size 1, and a new leading one, repeat.
    tensor<i32, 2> one = c[1, 1..2, ..];
    tensor<i32, 3> b = one.broadcast(2, 3, 4);
    show3("broadcast(2, 3, 4)", b);
    Stdio.printf("b %d %d %d\n", b[0, 0, 1], b[1, 2, 1], b[1, 1, 3]);

    // Writes through a view are writes to the storage.
    tensor<i32, 2> w = c[.., 1, ..];
    w[1, 2] = -5;
    p[0, 0] = -7;
    Stdio.printf("through the base %d %d\n", c[1, 1, 2], c[1, 0, 1]);

    // view() of a contiguous tensor, reshape() of one that is not.
    tensor<i32, 2> v = c.view(4, 6);
    show2("c.view(4, 6)", v);
    Stdio.printf("v[2, 5] %d, c[1, 0, 1] %d\n", v[2, 5], c[1, 0, 1]);
    tensor<i32, 1> flat = mt.reshape(12);
    show1("mt.reshape(12)", flat);
    flat[0] = 999;
    Stdio.printf("reshape copied: flat %d %d %d, m[0, 0] %d\n", flat[0], flat[1], flat[4], m[0, 0]);
    tensor<i32, 2> same = m.reshape(4, 3);
    show2("m.reshape(4, 3)", same);

    // copy(): a contiguous storage of its own with the same elements.
    tensor<i32, 2> cc = mts.copy();
    show2("copy", cc);
    cc[0, 0] = 1234;
    dump2(cc);
    Stdio.printf("source untouched %d\n", mts[0, 0]);

    // f4: strides count elements, so a slice starts at any element.
    tensor<f4, 1> q = new tensor<f4, 1>(9);
    for (u64 i = 0; i < 9; i++)
        q[i] = (f4)((f32)(i % 4) * 0.5);
    tensor<f4, 1> qs = q[3..8];
    qs[0] = 3.0;
    qs[2] = -1.0;
    Stdio.printf("f4 offset %d: q %.1f %.1f %.1f %.1f, qs %.1f %.1f\n", (i32)qs.offset(), (f32)q[2], (f32)q[3],
                 (f32)q[4], (f32)q[5], (f32)qs[1], (f32)qs[4]);
    tensor<f4, 1> qq = qs[1...3];
    qq[2] = 6.0;
    Stdio.printf("f4 slice of a slice offset %d: q[6] %.1f q[7] %.1f\n", (i32)qq.offset(), (f32)q[6], (f32)q[7]);
    tensor<f4, 1> qc = qq.copy();
    Stdio.printf("f4 copy %.1f %.1f %.1f\n", (f32)qc[0], (f32)qc[1], (f32)qc[2]);

    // The storage goes only when its last view goes.
    u64 before = TensorStorage.live();
    tensor<i32, 1> keep;
        {
        tensor<i32, 1> base = new tensor<i32, 1>(5);
        base[2] = 42;
        keep = middle(base);
        Stdio.printf("live inside %d\n", (i32)(TensorStorage.live() - before));
        }
    Stdio.printf("live after the base %d, keep[1] %d\n", (i32)(TensorStorage.live() - before), keep[1]);
    keep = a;
    Stdio.printf("live after the view %d\n", (i32)(TensorStorage.live() - before));
    return 0;
    }
