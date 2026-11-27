// tensors.xc — tensor<T, R> values: creation, elements, members, copies
// that share a storage, and the storage going with the last value.
#import "Stdio.xc"

tensor<f32, 2> identity(u64 n)
{
    tensor<f32, 2> m = new tensor<f32, 2>(n, n);
    for (u64 i = 0; i < n; i++)
        m[i, i] = 1.0;
    return m;
}

f32 trace(tensor<f32, 2> m)
{
    f32 s = 0.0;
    for (u64 i = 0; i < m.shape(0); i++)
        s += m[i, i];
    return s;
}

i32 main(void)
{
    tensor<f32, 2> m = identity(3);
    m[0, 2] = 2.5;
    m[1, 1] += 4.0;
    Stdio.printf("rank %d, %d x %d, %d elements\n", (i32)m.rank, (i32)m.shape(0), (i32)m.shape(1), (i32)m.count);
    Stdio.printf("strides %d %d, contiguous %d\n", (i32)m.stride(0), (i32)m.stride(1), m.isContiguous ? 1 : 0);
    Stdio.printf("trace %.1f\n", trace(m));

    tensor<f32, 2> view = m;          // the same storage
    view[2, 0] = 7.0;
    Stdio.printf("m[2, 0] %.1f\n", m[2, 0]);

    f32* p = m.data();                // row major: element [0, 2] is p[2]
    Stdio.printf("p[2] %.1f\n", p[2]);
    Stdio.printf("storages alive %d\n", (i32)TensorStorage.live());
    return 0;
}
