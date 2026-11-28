// tensor_expr_alias.xc — writes in place whose destination shares storage
// with an operand. Element by element at the same offset and strides (`a +=
// a`, `a[.., ..] = a * 2`), each element reads its own position before it is
// written, so the kernel runs in place, in parallel. At another offset or
// with other strides (a shifted slice of the same storage, a transpose, a
// broadcast row of the destination itself), the value goes through a
// temporary first. Where the sharing is known only as the program runs (two
// parameters), the kernel looks at the storages then. Each result is checked
// against a serial reference computed element by element from a copy.
//xtc-na: xt6502 — tensors are not available there
#import "Stdio.xc"

void report(u8* what, u32 bad)
{
    if (bad == 0)
        Stdio.printf("%s ok\n", what);
    else
        Stdio.printf("%s: %u wrong\n", what, bad);
}

tensor<i32, 1> ramp(u64 n)
{
    tensor<i32, 1> t = new tensor<i32, 1>(n);
    for (u64 j = 0; j < n; j++)
        t[j] = (i32)(j * 3 + 1);
    return t;
}

void same_layout(void)
{
    tensor<i32, 1> a = ramp(100);
    tensor<i32, 1> ref = a.copy();
    a += a;
    a[..] = a * 2 + a;
    u32 bad = 0;
    for (u64 j = 0; j < 100; j++)
        if (a[j] != (ref[j] + ref[j]) * 3)
            bad++;
    report("same layout", bad);
}

void shifted(void)
{
    // Forward: each element reads its left neighbour's old value.
    tensor<i32, 1> a = ramp(50);
    tensor<i32, 1> ref = a.copy();
    a[1..] = a[..49] * 2 + 1;
    u32 bad = a[0] != ref[0] ? 1 : 0;
    for (u64 j = 1; j < 50; j++)
        if (a[j] != ref[j - 1] * 2 + 1)
            bad++;
    report("shifted right", bad);
    // Backward: each element reads its right neighbour's old value.
    tensor<i32, 1> b = ramp(50);
    tensor<i32, 1> rb = b.copy();
    b[..49] -= b[1..];
    bad = b[49] != rb[49] ? 1 : 0;
    for (u64 j = 0; j < 49; j++)
        if (b[j] != rb[j] - rb[j + 1])
            bad++;
    report("shifted left", bad);
}

void transposed(void)
{
    tensor<i32, 2> m = new tensor<i32, 2>(6, 6);
    for (u64 i = 0; i < 6; i++)
        for (u64 j = 0; j < 6; j++)
            m[i, j] = (i32)(i * 6 + j);
    tensor<i32, 2> ref = m.copy();
    m[.., ..] = m.transpose() - m;
    u32 bad = 0;
    for (u64 i = 0; i < 6; i++)
        for (u64 j = 0; j < 6; j++)
            if (m[i, j] != ref[j, i] - ref[i, j])
                bad++;
    report("transposed", bad);
    tensor<i32, 2> n = ref.copy();
    n += n[2, ..];
    bad = 0;
    for (u64 i = 0; i < 6; i++)
        for (u64 j = 0; j < 6; j++)
            if (n[i, j] != ref[i, j] + ref[2, j])
                bad++;
    report("broadcast row of itself", bad);
}

// Whether `d` and `s` share a storage is known only here, at run time.
void scale_into(tensor<i32, 1> d, tensor<i32, 1> s)
{
    d[..] = s * 10 + d;
}

void at_run_time(void)
{
    tensor<i32, 1> a = ramp(40);
    tensor<i32, 1> ref = a.copy();
    scale_into(a[..39], a[1..]);
    u32 bad = a[39] != ref[39] ? 1 : 0;
    for (u64 j = 0; j < 39; j++)
        if (a[j] != ref[j + 1] * 10 + ref[j])
            bad++;
    report("overlap at run time", bad);
    tensor<i32, 1> b = ramp(40);
    tensor<i32, 1> c = ramp(40);
    scale_into(b, c);
    bad = 0;
    for (u64 j = 0; j < 40; j++)
        if (b[j] != ref[j] * 11)
            bad++;
    report("two storages at run time", bad);
    scale_into(c, c);
    bad = 0;
    for (u64 j = 0; j < 40; j++)
        if (c[j] != ref[j] * 11)
            bad++;
    report("one storage, same layout, at run time", bad);
}

void large(void)
{
    // Big enough to run on the CPU's threads: the temporary keeps the
    // pieces from reading what another piece has written.
    tensor<i32, 1> a = ramp(100000);
    tensor<i32, 1> ref = a.copy();
    a[1..] = a[..99999] + 7;
    u32 bad = 0;
    for (u64 j = 1; j < 100000; j++)
        if (a[j] != ref[j - 1] + 7)
            bad++;
    report("shifted, 100000 elements", bad);
    a[..] = a * 3 - a;
    bad = a[0] != ref[0] * 2 ? 1 : 0;
    for (u64 j = 1; j < 100000; j++)
        if (a[j] != (ref[j - 1] + 7) * 2)
            bad++;
    report("same layout, 100000 elements", bad);
}

i32 main(void)
{
    same_layout();
    shifted();
    transposed();
    at_run_time();
    large();
    Stdio.printf("storages %d\n", (i32)TensorStorage.live());
    return 0;
}
