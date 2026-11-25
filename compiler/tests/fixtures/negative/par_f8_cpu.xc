// A par block that computes in f8 runs on the CPU, and the compiler says why
// where it could otherwise have used the GPU.
// xtc: warn "this 'par' block runs on the CPU only, because it computes in f16, bf16 or f8, which GPU kernels do not take yet"
#import "Stdio.xc"
#import "Par.xc"

#define N 1024

f8 a[N];

i32 main(void)
{
    par scale :device(gpu)
    {
        for (u32 i in 0..N)
            a[i] = (f8)i * 0.5;
    }
    Stdio.printf("%f\n", a[N - 1]);
    return 0;
}
