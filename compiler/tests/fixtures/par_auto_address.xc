//xtc-flags: target=arm64 --par-style=auto
//xtc-na: xt6502, m68k, arm9, wasm32 — par runs on the native hosts
// par_auto_address.xc — with --par-style=auto, a loop whose body takes the
// address of an outer variable, or of an element or member of one, stays a
// loop (#510): a call can write through the address, and as a block every
// work item would write it at once. Each of the first four loops feeds one
// value through every iteration, so only the loop as written gives the
// answer. A bitwise `&` takes no address, and the address of the body's own
// local reaches nothing outside the item: those loops become blocks.
#import "Stdio.xc"
#define N 200000
struct Acc { u64 v; u32 n; }
u32 a[N];
u32 b[N];
u32 o1[N];
u32 o2[N];
u64 o3[N];
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
i32 main(i32 argc, u8** argv)
{
    u64 c[1];
    c[0] = (u64)argc;
    for (u32 i = 0; i < N; i++)
        step(&c[0], &c[0], (u64)i);
    Acc s;
    s.v = (u64)1469598103934665603;
    for (u32 i in 0..N)
        bump(&s.v, (u64)i);
    u64 h = 7;
    for (u32 i in 0..N)
        bump(&h, (u64)i);
    u64* p = &c[0];
    for (u32 i in 0..N)
        bump(&*p, (u64)i);
    for (u32 i in 0..N) {
        a[i] = i * 2654435761;
        b[i] = i ^ 1431655765;
    }
    u32 m = (u32)argc + 65534;
    for (u32 i in 0..N)
        o1[i] = m & b[i];
    for (u32 i in 0..N)
        o2[i] = a[i] & b[i];
    for (u32 i in 0..N) {
        u64 t = (u64)i;
        sq(&t);
        o3[i] = t;
    }
    u64 s1 = 0;
    u64 s2 = 0;
    u64 s3 = 0;
    for (u32 i in 0..N)
        s1 += (u64)o1[i];
    for (u32 i in 0..N)
        s2 += (u64)o2[i];
    for (u32 i in 0..N)
        s3 += o3[i];
    Stdio.printf("c=%llu s=%llu h=%llu\n", c[0], s.v, h);
    Stdio.printf("o1=%llu o2=%llu o3=%llu\n", s1, s2, s3);
    return 0;
}
