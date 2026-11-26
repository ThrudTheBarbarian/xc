// A par block that computes in f8 has a GPU kernel, which converts each value
// in the kernel. One that also uses double has none on Apple GPUs, and the
// compiler gives that reason, not the f8.
// xtc: target arm64-macos
// xtc: warn "this 'par' block runs on the CPU only, because it uses double, which Apple GPUs do not have"
// xtc: nowarn "computes in f8"
#import "Stdio.xc"
#import "Par.xc"

#define N 1024

f8 a[N];
f8 b[N];

i32 main(void)
{
    par scale :device(gpu)
    {
        for (u32 i in 0..N)
            a[i] = (f8)i * 0.5;
    }
    par wide :device(gpu)
    {
        for (u32 i in 0..N)
            b[i] = (f8)((f64)i * 0.25);
    }
    Stdio.printf("%f %f\n", a[N - 1], b[N - 1]);
    return 0;
}
