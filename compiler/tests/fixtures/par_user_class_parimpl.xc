//xtc-flags: target=arm64
//xtc-na: xt6502 m68k arm9 — par needs threads
// A class of the program's own named ParImpl, with run() looping from its
// first field to its second, is not a par block's kernel: its items are not
// independent (each reads the one before), and it may call printf.
#import "Stdio.xc"
#import "Par.xc"

class ParImpl
    {
    i64 lo;
    i64 hi;
    i64* a;
    void run(void)
        {
        for (i64 i = self.lo; i < self.hi; i = i + (i64)1)
            self.a[i + (i64)1] = self.a[i] + self.a[i + (i64)1];
        Stdio.printf("run %ld..%ld\n", self.lo, self.hi);
        }
    }

i32 main(void)
    {
    i64* a = new i64[(u32)1001];
    for (u32 i in 0..1001)
        a[i] = (i64)1;
    ParImpl* p = new ParImpl();
    p.lo = (i64)0;
    p.hi = (i64)1000;
    p.a = a;
    p.run();
    Stdio.printf("%ld %ld %ld\n", a[1], a[500], a[1000]);

    u32 n = (u32)4096;
    float* x = new float[n];
    float* y = new float[n];
    for (u32 i in 0..n)
        x[i] = (float)i;
    par twice
        {
        for (u32 i in 0..n)
            y[i] = x[i] * 2.0f;
        }
    float s = 0.0f;
    for (u32 i in 0..n)
        s = s + y[i];
    Stdio.printf("%.1f\n", (double)s);
    return 0;
    }
