// par_fuse_scalar.xc — a fused block's intermediate array kept in a register
// (#147): an array the fused body writes and reads only at the index, a
// local set once with `new` and used nowhere else, holds each item's value
// for that item alone, so the block keeps it in a register and the array is
// neither read nor written (nor sent to a GPU). Arrays read after the block,
// passed elsewhere, or set twice stay arrays. Each case prints the same
// fused or apart (-fno-par-fuse); tests/par/fuse.sh checks which arrays the
// block kept (-Wpar-auto).
//
//xtc-na: xt6502, m68k, arm9, wasm32 — par runs on the native hosts
#import "Stdio.xc"
#import "Par.xc"

#define N 100003

float total(float* a)
{
    float s = 0.0;
    for (u32 i = 0; i < N; i++) : serial
        s = s + a[i];
    return s;
}

i32 main(void)
{
    float* x = new float[N];
    for (u32 i = 0; i < N; i++) : serial
        x[i] = (float)(i % 101) * 0.5;

    // Written blocks: y in a register; keep is read after, so stays.
    float* y = new float[N];
    float* keep = new float[N];
    float* z = new float[N];
    par w1 { for (u32 i in 0..N) { y[i] = x[i] * 2.0 + 1.0; keep[i] = x[i] + 3.0; } }
    par w2 { for (u32 i in 0..N) z[i] = y[i] * y[i] + keep[i]; }
    Stdio.printf("written: %.1f %.1f\n", total(z), total(keep));

    // Loops --par-style lifts: t in a register.
    float* t = new float[N];
    float* u = new float[N];
    for (u32 i in 0..N)
        t[i] = x[i] * 3.0;
    for (u32 i in 0..N)
        u[i] = t[i] + 1.0;
    Stdio.printf("lifted: %.1f\n", total(u));

    // Passed to a function after: stays an array.
    float* p = new float[N];
    float* q = new float[N];
    par a1 { for (u32 i in 0..N) p[i] = x[i] + 0.5; }
    par a2 { for (u32 i in 0..N) q[i] = p[i] * 2.0; }
    Stdio.printf("passed: %.1f %.1f\n", total(q), total(p));

    // Set twice: stays an array.
    float* r = new float[N];
    r = new float[N];
    float* v = new float[N];
    par b1 { for (u32 i in 0..N) r[i] = x[i] - 1.0; }
    par b2 { for (u32 i in 0..N) v[i] = r[i] * r[i]; }
    Stdio.printf("twice: %.1f\n", total(v));
    return 0;
}
