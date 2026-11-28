// tensor_expr_par.xc — tensor expressions large enough to run on the CPU's
// threads: the result is the same for any number of threads
// (tests/par/threads.sh runs it with 1, 2, 3 and 16). A contiguous result
// is cut into flat pieces, a broadcast or strided one into rows; an f4
// result (two elements to a byte) is cut where a byte starts, even with
// rows of odd length, and an in-place write through a shifted view goes
// through a temporary.
//xtc-na: xt6502 — tensors are not available there
#import "Stdio.xc"
#import "Math.xc"

u32 sumf(tensor<f32, 2> t)
{
    u32 h = 0;
    for (u64 i = 0; i < t.shape(0); i++)
        for (u64 j = 0; j < t.shape(1); j++)
        {
            f32 v = t[i, j];
            h = h * 31 + *(u32*)&v;
        }
    return h;
}

i32 main(void)
{
    u64 rows = 301;
    u64 cols = 257;
    tensor<f32, 2> a = new tensor<f32, 2>(rows, cols);
    tensor<f32, 2> b = new tensor<f32, 2>(rows, cols);
    tensor<f32, 1> c = new tensor<f32, 1>(cols);
    for (u64 i = 0; i < rows; i++)
        for (u64 j = 0; j < cols; j++)
        {
            a[i, j] = (f32)((i * 7 + j * 3) % 101) * 0.125 - 3.0;
            b[i, j] = (f32)((i + j * 5) % 37) * 0.5 + 0.25;
        }
    for (u64 j = 0; j < cols; j++)
        c[j] = (f32)(j % 13) - 6.0;
    tensor<f32, 2> flat = a * b + 1.5;
    tensor<f32, 2> rowsb = Math.sqrt(b) * a - c;
    tensor<f32, 2> strided = a.transpose().transpose() * 2.0 + b[.., ..];
    Stdio.printf("flat %x\n", sumf(flat));
    Stdio.printf("broadcast %x\n", sumf(rowsb));
    Stdio.printf("strided %x\n", sumf(strided));

    tensor<f4, 2> q = new tensor<f4, 2>(rows, cols);
    for (u64 i = 0; i < rows; i++)
        for (u64 j = 0; j < cols; j++)
            q[i, j] = (f4)((f32)((i + j) % 9) * 0.5 - 2.0);
    tensor<f4, 2> q2 = q * 1.5 + (tensor<f4, 1>)c;
    tensor<f4, 2> q3 = -q;
    u32 h = 0;
    for (u64 i = 0; i < rows; i++)
        for (u64 j = 0; j < cols; j++)
        {
            f4 v = q2[i, j];
            f4 w = q3[i, j];
            f4[] pv = &v;
            f4[] pw = &w;
            h = h * 31 + (u32)(*(u8*)pv & 15) * 16 + (u32)(*(u8*)pw & 15);
        }
    Stdio.printf("f4 %x\n", h);

    tensor<i32, 1> n = new tensor<i32, 1>(200001);
    for (u64 j = 0; j < 200001; j++)
        n[j] = (i32)(j % 1000);
    n[1..] = n[..200000] * 3 + 1;
    n += n;
    u32 g = 0;
    for (u64 j = 0; j < 200001; j++)
        g = g * 31 + (u32)n[j];
    Stdio.printf("shifted %x\n", g);
    return 0;
}
