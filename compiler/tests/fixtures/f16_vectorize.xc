// f16_vectorize.xc — loops over f16 and bf16 arrays: conversions to and from
// f32, chains of two to four operations rounded to the type after each, a
// square root and a sum, at odd lengths (a vector tail) and unaligned starts.
// Each result is computed twice, by a forward loop the vectoriser takes and a
// backward one it does not, and the two must agree bit for bit; a checksum of
// the forward results is printed. The specials (NaNs of both kinds, infinities,
// -0, subnormals, values past the type's range) sit in one operand of each
// operation only, since which payload an operation on two NaNs returns differs
// between targets. The checksum takes a NaN without its sign: an invalid
// operation's NaN is positive on arm64 and negative on x86-64.
//xtc-na: xt6502, m68k — fourteen 1031-element arrays and some 300000 software conversions
#import "Stdio.xc"
#import "Math.xc"

#define N 1031

f32 F[N];
f32 G[N];
f16 A[N];
f16 B[N];
f16 C[N];
f16 D[N];
f16 E[N];
bf16 GA[N];
bf16 GB[N];
bf16 GC[N];
bf16 GD[N];
bf16 GE[N];
f32 R[N];
f32 S[N];

u32 seed = 2463534242;

u32 next(void)
{
    seed = seed ^ (seed << 13);
    seed = seed ^ (seed >> 17);
    seed = seed ^ (seed << 5);
    return seed;
}

u32 mix(u32 h, u32 x) { return (h ^ x) * 16777619; }
u32 hb(f16 h) { return *(u16*)&h; }
u32 gb(bf16 g) { return *(u16*)&g; }
u32 fb(f32 f) { return *(u32*)&f; }
f16 hof(u32 b) { u16 x = (u16)b; return *(f16*)&x; }
bf16 gof(u32 b) { u16 x = (u16)b; return *(bf16*)&x; }
f32 fof(u32 b) { return *(f32*)&b; }

// The specials, one in eight elements of the first operand.
u32 special16(u32 k)
{
    u32 s[12] = { 0x7C01, 0xFDFF, 0x7E00, 0xFE01, 0x7C00, 0xFC00, 0x8000, 0x0001, 0x83FF, 0x7BFF, 0x0400, 0x7D55 };
    return s[k % 12];
}
u32 specialB(u32 k)
{
    u32 s[12] = { 0x7F81, 0xFFBF, 0x7FC0, 0xFFC1, 0x7F80, 0xFF80, 0x8000, 0x0001, 0x807F, 0x7F7F, 0x0080, 0x7FA5 };
    return s[k % 12];
}
u32 special32(u32 k)
{
    u32 s[12] = { 0x7F800001, 0xFFBFFFFF, 0x7FC00000, 0x7F801234, 0x7F800000, 0xFF800000, 0x80000000, 0x00000001,
                  0x477FF000, 0x477FEFFF, 0x387FC000, 0x33000001 };
    return s[k % 12];
}

void fill(void)
{
    for (u32 i = 0; i < N; i++)
        {
        u32 r = next();
        f32 v = (f32)(i32)(r % 40000) * 0.01 - 200.0;
        F[i] = (r & 7) == 0 ? fof(special32(r >> 3)) : v * (f32)(1 + (r >> 29));
        G[i] = (f32)(i32)((r >> 7) % 3000) * 0.001 + 0.25;
        A[i] = (r & 7) == 1 ? hof(special16(r >> 3)) : (f16)(v * 0.37);
        B[i] = (f16)((f32)(i32)((r >> 5) % 2000) * 0.003 + 0.5);
        C[i] = (f16)((f32)(i32)((r >> 9) % 5000) * 0.02 - 50.0);
        GA[i] = (r & 7) == 2 ? gof(specialB(r >> 3)) : (bf16)(v * 1.7e30);
        GB[i] = (bf16)((f32)(i32)((r >> 5) % 2000) * 0.003 + 0.5);
        GC[i] = (bf16)((f32)(i32)((r >> 9) % 5000) * 0.02 - 50.0);
        }
}

// The kernels, forward. Each takes its start and end, so the trip is a
// run-time one, and pointers, so the bases are not known objects.
void k_from(f16* h, f32* f, u32 s, u32 n) { for (u32 i = s; i < n; i++) h[i] = (f16)f[i]; }
void k_to(f32* f, f16* h, u32 s, u32 n) { for (u32 i = s; i < n; i++) f[i] = (f32)h[i]; }
void k_fma(f16* d, f16* a, f16* b, f16* c, u32 s, u32 n) { for (u32 i = s; i < n; i++) d[i] = a[i] * b[i] + c[i]; }
void k_ch3(f16* d, f16* a, f16* b, f16* c, u32 s, u32 n) { for (u32 i = s; i < n; i++) d[i] = (a[i] + b[i]) * c[i] - b[i]; }
void k_ch4(f16* d, f16* a, f16* b, f16* c, u32 s, u32 n) { for (u32 i = s; i < n; i++) d[i] = ((a[i] * b[i] + c[i]) / b[i]) * c[i]; }
void k_sqrt(f16* d, f16* a, f16* b, f16* c, u32 s, u32 n) { for (u32 i = s; i < n; i++) d[i] = (f16)Math.sqrt((f32)(a[i] * b[i] + c[i])); }
void k_mixed(f32* r, f16* a, f16* b, f32* g, u32 s, u32 n) { for (u32 i = s; i < n; i++) r[i] = (f32)(a[i] * b[i]) * g[i] + (f32)a[i]; }
void k_scale(f16* d, f16* a, f16 k, u32 s, u32 n) { for (u32 i = s; i < n; i++) d[i] = a[i] * k + (f16)1.5; }
void g_from(bf16* h, f32* f, u32 s, u32 n) { for (u32 i = s; i < n; i++) h[i] = (bf16)f[i]; }
void g_to(f32* f, bf16* h, u32 s, u32 n) { for (u32 i = s; i < n; i++) f[i] = (f32)h[i]; }
void g_fma(bf16* d, bf16* a, bf16* b, bf16* c, u32 s, u32 n) { for (u32 i = s; i < n; i++) d[i] = a[i] * b[i] + c[i]; }
void g_ch3(bf16* d, bf16* a, bf16* b, bf16* c, u32 s, u32 n) { for (u32 i = s; i < n; i++) d[i] = (a[i] + b[i]) * c[i] - b[i]; }
void g_ch4(bf16* d, bf16* a, bf16* b, bf16* c, u32 s, u32 n) { for (u32 i = s; i < n; i++) d[i] = ((a[i] * b[i] + c[i]) / b[i]) * c[i]; }
f32 k_sum(f16* h, u32 s, u32 n) { f32 t = 0.0; for (u32 i = s; i < n; i++) t = t + (f32)h[i]; return t; }
f32 g_sum(bf16* h, u32 s, u32 n) { f32 t = 0.0; for (u32 i = s; i < n; i++) t = t + (f32)h[i]; return t; }

// The same, backward: the vectoriser takes no loop that counts down.
void r_from(f16* h, f32* f, u32 s, u32 n) { for (u32 i = n; i > s; i--) h[i - 1] = (f16)f[i - 1]; }
void r_to(f32* f, f16* h, u32 s, u32 n) { for (u32 i = n; i > s; i--) f[i - 1] = (f32)h[i - 1]; }
void r_fma(f16* d, f16* a, f16* b, f16* c, u32 s, u32 n) { for (u32 i = n; i > s; i--) d[i - 1] = a[i - 1] * b[i - 1] + c[i - 1]; }
void r_ch3(f16* d, f16* a, f16* b, f16* c, u32 s, u32 n) { for (u32 i = n; i > s; i--) d[i - 1] = (a[i - 1] + b[i - 1]) * c[i - 1] - b[i - 1]; }
void r_ch4(f16* d, f16* a, f16* b, f16* c, u32 s, u32 n) { for (u32 i = n; i > s; i--) d[i - 1] = ((a[i - 1] * b[i - 1] + c[i - 1]) / b[i - 1]) * c[i - 1]; }
void r_sqrt(f16* d, f16* a, f16* b, f16* c, u32 s, u32 n) { for (u32 i = n; i > s; i--) d[i - 1] = (f16)Math.sqrt((f32)(a[i - 1] * b[i - 1] + c[i - 1])); }
void r_mixed(f32* r, f16* a, f16* b, f32* g, u32 s, u32 n) { for (u32 i = n; i > s; i--) r[i - 1] = (f32)(a[i - 1] * b[i - 1]) * g[i - 1] + (f32)a[i - 1]; }
void r_scale(f16* d, f16* a, f16 k, u32 s, u32 n) { for (u32 i = n; i > s; i--) d[i - 1] = a[i - 1] * k + (f16)1.5; }
void q_from(bf16* h, f32* f, u32 s, u32 n) { for (u32 i = n; i > s; i--) h[i - 1] = (bf16)f[i - 1]; }
void q_to(f32* f, bf16* h, u32 s, u32 n) { for (u32 i = n; i > s; i--) f[i - 1] = (f32)h[i - 1]; }
void q_fma(bf16* d, bf16* a, bf16* b, bf16* c, u32 s, u32 n) { for (u32 i = n; i > s; i--) d[i - 1] = a[i - 1] * b[i - 1] + c[i - 1]; }
void q_ch3(bf16* d, bf16* a, bf16* b, bf16* c, u32 s, u32 n) { for (u32 i = n; i > s; i--) d[i - 1] = (a[i - 1] + b[i - 1]) * c[i - 1] - b[i - 1]; }
void q_ch4(bf16* d, bf16* a, bf16* b, bf16* c, u32 s, u32 n) { for (u32 i = n; i > s; i--) d[i - 1] = ((a[i - 1] * b[i - 1] + c[i - 1]) / b[i - 1]) * c[i - 1]; }

u32 bad = 0;

u32 cmpH(f16* x, f16* y, u32 n)
{
    u32 h = 2166136261;
    for (u32 i = 0; i < n; i++)
        {
        if (hb(x[i]) != hb(y[i]))
            bad++;
        u32 b = hb(x[i]);
        h = mix(h, (b & 0x7FFF) > 0x7C00 ? b & 0x7FFF : b);
        }
    return h;
}
u32 cmpG(bf16* x, bf16* y, u32 n)
{
    u32 h = 2166136261;
    for (u32 i = 0; i < n; i++)
        {
        if (gb(x[i]) != gb(y[i]))
            bad++;
        u32 b = gb(x[i]);
        h = mix(h, (b & 0x7FFF) > 0x7F80 ? b & 0x7FFF : b);
        }
    return h;
}
u32 cmpF(f32* x, f32* y, u32 n)
{
    u32 h = 2166136261;
    for (u32 i = 0; i < n; i++)
        {
        if (fb(x[i]) != fb(y[i]))
            bad++;
        u32 b = fb(x[i]);
        h = mix(h, (b & 0x7FFFFFFF) > 0x7F800000 ? b & 0x7FFFFFFF : b);
        }
    return h;
}

void clear(void)
{
    for (u32 i = 0; i < N; i++)
        {
        D[i] = hof(0x5555);
        E[i] = hof(0x5555);
        GD[i] = gof(0x5555);
        GE[i] = gof(0x5555);
        R[i] = fof(0x55555555);
        S[i] = fof(0x55555555);
        }
}

i32 main(void)
{
    fill();
    u32 lens[7] = { 1, 3, 7, 8, 13, 100, 1031 };
    u32 starts[3] = { 0, 1, 3 };
    u32 h = 2166136261;
    f32 sums = 0.0;
    for (u32 li = 0; li < 7; li++)
        for (u32 si = 0; si < 3; si++)
            {
            u32 n = lens[li], s = starts[si];
            if (s > n)
                continue;
            clear(); k_from(&D[0], &F[0], s, n); r_from(&E[0], &F[0], s, n); h = mix(h, cmpH(&D[0], &E[0], N));
            clear(); k_to(&R[0], &A[0], s, n); r_to(&S[0], &A[0], s, n); h = mix(h, cmpF(&R[0], &S[0], N));
            clear(); k_fma(&D[0], &A[0], &B[0], &C[0], s, n); r_fma(&E[0], &A[0], &B[0], &C[0], s, n); h = mix(h, cmpH(&D[0], &E[0], N));
            clear(); k_ch3(&D[0], &A[0], &B[0], &C[0], s, n); r_ch3(&E[0], &A[0], &B[0], &C[0], s, n); h = mix(h, cmpH(&D[0], &E[0], N));
            clear(); k_ch4(&D[0], &A[0], &B[0], &C[0], s, n); r_ch4(&E[0], &A[0], &B[0], &C[0], s, n); h = mix(h, cmpH(&D[0], &E[0], N));
            clear(); k_sqrt(&D[0], &A[0], &B[0], &C[0], s, n); r_sqrt(&E[0], &A[0], &B[0], &C[0], s, n); h = mix(h, cmpH(&D[0], &E[0], N));
            clear(); k_mixed(&R[0], &A[0], &B[0], &G[0], s, n); r_mixed(&S[0], &A[0], &B[0], &G[0], s, n); h = mix(h, cmpF(&R[0], &S[0], N));
            clear(); k_scale(&D[0], &A[0], (f16)0.75, s, n); r_scale(&E[0], &A[0], (f16)0.75, s, n); h = mix(h, cmpH(&D[0], &E[0], N));
            clear(); g_from(&GD[0], &F[0], s, n); q_from(&GE[0], &F[0], s, n); h = mix(h, cmpG(&GD[0], &GE[0], N));
            clear(); g_to(&R[0], &GA[0], s, n); q_to(&S[0], &GA[0], s, n); h = mix(h, cmpF(&R[0], &S[0], N));
            clear(); g_fma(&GD[0], &GA[0], &GB[0], &GC[0], s, n); q_fma(&GE[0], &GA[0], &GB[0], &GC[0], s, n); h = mix(h, cmpG(&GD[0], &GE[0], N));
            clear(); g_ch3(&GD[0], &GA[0], &GB[0], &GC[0], s, n); q_ch3(&GE[0], &GA[0], &GB[0], &GC[0], s, n); h = mix(h, cmpG(&GD[0], &GE[0], N));
            clear(); g_ch4(&GD[0], &GA[0], &GB[0], &GC[0], s, n); q_ch4(&GE[0], &GA[0], &GB[0], &GC[0], s, n); h = mix(h, cmpG(&GD[0], &GE[0], N));
            sums = sums + k_sum(&B[0], s, n) + g_sum(&GB[0], s, n);
            }
    // Unaligned bases: the arrays seen from an odd element.
    clear(); k_fma(&D[1], &A[3], &B[2], &C[5], 0, 1001); r_fma(&E[1], &A[3], &B[2], &C[5], 0, 1001); h = mix(h, cmpH(&D[0], &E[0], N));
    clear(); g_fma(&GD[3], &GA[1], &GB[2], &GC[7], 0, 1001); q_fma(&GE[3], &GA[1], &GB[2], &GC[7], 0, 1001); h = mix(h, cmpG(&GD[0], &GE[0], N));
    clear(); k_from(&D[1], &F[2], 0, 1001); r_from(&E[1], &F[2], 0, 1001); h = mix(h, cmpH(&D[0], &E[0], N));
    // In place, and overlapping by an element: the scalar order must hold.
    for (u32 i = 0; i < N; i++) { D[i] = A[i]; E[i] = A[i]; }
    k_fma(&D[0], &D[0], &B[0], &C[0], 0, 1001); r_fma(&E[0], &E[0], &B[0], &C[0], 0, 1001); h = mix(h, cmpH(&D[0], &E[0], N));
    for (u32 i = 0; i < N; i++) { D[i] = A[i]; E[i] = A[i]; }
    k_fma(&D[1], &D[0], &B[0], &C[0], 0, 1001);
    for (u32 i = 0; i < 1001; i++) E[i + 1] = E[i] * B[i] + C[i];
    h = mix(h, cmpH(&D[0], &E[0], N));
    for (u32 i = 0; i < N; i++) { R[i] = F[i]; S[i] = F[i]; }
    k_from((f16*)&R[0], &R[0], 0, 1001);
    // Forward, as the scalar loop runs: a loop with a call in it is not vectorised.
    f16* sh = (f16*)&S[0];
    for (u32 i = 0; i < 1001; i++)
        {
        sh[i] = (f16)S[i];
        if (bad > 1000000)
            Stdio.printf("?");
        }
     h = mix(h, cmpF(&R[0], &S[0], N));
    Stdio.printf("mismatches %ld\n", (i32)bad);
    Stdio.printf("checksum %x\n", h);
    Stdio.printf("sums %x\n", fb(sums));
    return 0;
}
