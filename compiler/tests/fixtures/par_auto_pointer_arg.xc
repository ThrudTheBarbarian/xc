//xtc-flags: target=arm64 --par-style=auto
//xtc-na: xt6502, m68k, arm9, wasm32 — par runs on the native hosts
// par_auto_pointer_arg.xc — with --par-style=auto, a loop whose body passes
// an outer array or pointer to a call stays a loop (#512): the call can write
// through it, and as a block every work item would write it at once. A member
// passed to a call stays a loop too, since the compiler cannot tell a pointer
// member from a number, and so does a call's result, even through a local
// named like a function that returns a number. Each of the first seven loops
// feeds one value through every iteration, so only the loop as written gives
// the answer. An element's value, the loop variable, the body's own array, a
// function declared to return a number and Math's built-ins reach nothing
// outside the item: those loops become blocks.
#import "Stdio.xc"
#import "Math.xc"
#define N 200000
u32 a[N];
u32 o1[N];
u64 o2[N];
u64 o3[N];
double o4[N];
u64 g[2];
struct Box { u64* p; u32 n; }
u64 h[1];
void step(u64* o, u64* x, u64 k)
{
    o[0] = (x[0] * (u64)6364136223846793005) + k;
}
void bump(u64* p, u64 k)
{
    *p = (*p ^ k) * (u64)1099511628211;
}
void sq(u64* p)
{
    *p = *p * *p + (u64)1;
}
u64* cell(void)
{
    return h;
}
typedef u64* pick_t(u32);
u64* pickH(u32 k)
{
    return h;
}
u32 mix(u32 x)
{
    return (x ^ (x >> 15)) * 2246822519;
}
i32 main(i32 argc, u8** argv)
{
    u64 c[1];
    c[0] = (u64)argc;
    for (u32 i = 0; i < N; i++)
        step(c, c, (u64)i);
    u64 d[2];
    d[0] = 7;
    d[1] = 9;
    u64* p = d;
    for (u32 i in 0..N)
        bump(p, (u64)i);
    for (u32 i in 0..N)
        bump(p + 1, (u64)i);
    g[1] = 5;
    for (u32 i in 0..N)
        bump((u64*)g + 1, (u64)i);
    u64 e[1];
    e[0] = 3;
    Box bx;
    bx.p = e;
    bx.n = 2;
    for (u32 i in 0..N)
        bump(bx.p, (u64)i);
    h[0] = 11;
    for (u32 i in 0..N)
        bump(cell(), (u64)i);
    {
        // A local named like the top-level `mix`, which returns a number:
        // the call is through the local, and hands back a pointer.
        pick_t* mix = &pickH;
        for (u32 i in 0..N)
            bump(mix(i), (u64)i);
    }
    for (u32 i in 0..N)
        a[i] = i * 2654435761;
    for (u32 i in 0..N)
        o1[i] = mix(a[i]);
    for (u32 i in 0..N)
        o2[i] = (u64)mix(mix(i));
    for (u32 i in 0..N) {
        u64 t[1];
        t[0] = (u64)i;
        sq(t);
        o3[i] = t[0];
    }
    for (u32 i in 0..N)
        o4[i] = Math.sqrt(Math.abs((double)a[i]));
    u64 s1 = 0;
    u64 s2 = 0;
    u64 s3 = 0;
    double s4 = 0.0;
    for (u32 i in 0..N)
        s1 += (u64)o1[i];
    for (u32 i in 0..N)
        s2 += o2[i];
    for (u32 i in 0..N)
        s3 += o3[i];
    for (u32 i = 0; i < N; i++) : serial
        s4 = s4 + o4[i];
    Stdio.printf("c=%llu d0=%llu d1=%llu g1=%llu e0=%llu h0=%llu\n", c[0], d[0], d[1], g[1], e[0], h[0]);
    Stdio.printf("o1=%llu o2=%llu o3=%llu o4=%.3f\n", s1, s2, s3, s4);
    return 0;
}
