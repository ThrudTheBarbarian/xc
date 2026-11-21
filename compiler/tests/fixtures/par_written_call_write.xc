//xtc-warn: a 'par' block passes 'c[0]' to a call that may write through it, from every work item
//xtc-warn: a 'par' block passes 'd' to a call that may write through it, from every work item
//xtc-warn: a 'par' block passes 'g' at an index computed from data to a call that may write through it
//xtc-warn: a 'par' block passes 'h' to a call that may write through it, from every work item
//xtc-warn: this 'par' block runs on the CPU only
//xtc-na: xt6502, m68k, arm9, wasm32 — par runs on the native hosts
// par_written_call_write.xc — a written `par` block that passes an outer
// array or pointer to a call that writes through it, other than at the
// item's own element, may have two items write the same element (#513): it
// builds as written, with the warning a direct write of one element from
// every item gets (par-scatter). The first four blocks race, so their results
// are not printed: the element itself, the pointer itself, an element at an
// index from data, and the pointer handed on by a helper (which keeps that
// block off a Metal GPU, as the fifth line lets through). An element at the
// item's own index and a call that only reads say nothing.
#import "Stdio.xc"
#import "Par.xc"

#define N 4096

u64 g[16];

void step(u64* o, u64* a, u64 k)
{
    o[0] = (a[0] * (u64)6364136223846793005) + k;
}

void stepVia(u64* p, u64 k)
{
    step(p, p, k);
}

void put(u64* p, u64 v)
{
    p[0] = v;
}

u64 peekAt(u64* a, u32 i)
{
    return a[i] + 1;
}

i32 main(i32 argc, u8** argv)
{
    u64 c[1];
    c[0] = (u64)argc;
    par { for (u32 a = 0; a < 200000; a++) step(&c[0], &c[0], (u64)a); }
    u64* d = new u64[4];
    d[0] = 1;
    par { for (u32 a = 0; a < 200000; a++) step(d, d, (u64)a); }
    u32* idx = new u32[N];
    for (u32 i = 0; i < N; i++)
        idx[i] = (i * 7) % 16;
    par { for (u32 a in 0..N) step(&g[idx[a]], &g[idx[a]], (u64)a); }
    u64* h = new u64[2];
    par { for (u32 a in 0..N) stepVia(h, (u64)a); }
    u64* e = new u64[N];
    par { for (u32 i in 0..N) put(&e[i], (u64)i * 3); }
    u64* f = new u64[N];
    par { for (u32 i in 0..N) f[i] = peekAt(e, i); }
    u64 se = 0;
    u64 sf = 0;
    for (u32 i = 0; i < N; i++) {
        se += e[i];
        sf += f[i];
    }
    Stdio.printf("%llu %llu\n", se, sf);
    return 0;
}
