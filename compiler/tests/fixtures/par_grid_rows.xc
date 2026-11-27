// A par :grid block over small heap arrays (#776): c[par.y * n + par.x] is
// the item itself (n is the grid's width), and a[par.y * kk + k] is whole
// rows of kk, so the runtime knows each array's extent and does not take
// the two 16 KB arrays for one block of memory. The output is the serial one.
#import "Stdio.xc"
#import "Par.xc"
void mv(float* a, float* b, float* c, u32 m, u32 n, u32 kk)
    {
    par mv :grid(n, m)
        {
        float s = 0.0;
        for (u32 k = (u32)0; k < kk; k++)
            s = s + a[par.y * kk + k] * b[k * n + par.x];
        c[par.y * n + par.x] = s;
        }
    }
i32 main(void)
    {
    u32 m = (u32)1;
    u32 n = (u32)4096;
    u32 kk = (u32)1024;
    float* a = new float[m * kk];
    float* b = new float[kk * n];
    float* c = new float[m * n];
    for (u32 i = (u32)0; i < m * kk; i++) : serial
        a[i] = (float)(i % (u32)7) * 0.5;
    for (u32 i = (u32)0; i < kk * n; i++) : serial
        b[i] = (float)(i % (u32)5) * 0.25;
    mv(a, b, c, m, n, kk);
    double s = 0.0;
    for (u32 j = (u32)0; j < n; j++) : serial
        s = s + (double)c[j];
    Stdio.printf("%.3f\n", s);
    return 0;
    }
