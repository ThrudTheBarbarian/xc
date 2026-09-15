// m68k_loop_var_parallel_copy.xc — guard for bug 022 (parallel phi copies).
//
// An outer loop counter (`lc4`) stored into a local (`v0 = lc4`) inside a
// nested loop must read back as the LAST value the inner loop stored (4), not
// the counter's post-loop value (5). After the inner loop unrolls, `v0`'s phi
// source copy-propagates to `lc4`, so the outer latch emits two PARALLEL phi
// copies whose dest/source locations alias: `lc4 <- lc4+1` and `v0 <- lc4`.
// Writing lc4 first hands v0 the post-increment value (a lost copy) → v0 = 5.
//
// The fuzzer (arm64/xt6502/m68k, seed 20176) caught it on m68k, but the same
// root cause — a phi-copy emitter that didn't order/snapshot around a dest that
// is another copy's source — also miscompiled x86_64 and arm9. arm64 and xt6502
// were correct (they already emit phi copies in dependency order). Fixed each of
// m68k (slot-aware safety + stack shuffle), x86_64 (ditto, rbp-relative) and
// arm9 (dependency-order — its slots are sp-relative, so a stack shuffle can't
// be used). Heap/ARC pressure is what spills the counter to a slot so the hazard
// bites; the churn() calls below supply it.
//
// Expected (all backends): "4 3053453312 23 23 4294967223 6" then "2".
#import "Stdio.xc"

struct S0 { i8 f0; i8 f1; u8 f2; }
S0 mkS0(i8 a0, i8 a1, u8 a2) { S0 rr; rr.f0 = a0; rr.f1 = a1; rr.f2 = a2; return rr; }
i32 useS0(S0 s) { return (i32)((i32)(s.f0) + (i32)(s.f1) + (i32)(s.f2)); }
struct S1 { u16 f0; u8 f1; }
S1 mkS1(u16 a0, u8 a1) { S1 rr; rr.f0 = a0; rr.f1 = a1; return rr; }
u16 useS1(S1 s) { return (u16)((u16)(s.f0) + (u16)(s.f1)); }
i8 g0;
class K0 {
    u16 iv0;
    u32 iv1;
    u32 iv2;
    void init(void) { iv0 = 39993; iv1 = 2538273026; iv2 = 3160454074; }
    void setvals(u16 a0, u32 a1, u32 a2) { iv0 = a0; iv1 = a1; iv2 = a2; }
    u16 mix(void) { return (u16)((u16)((g0 << (g0 & (i8)7)) + (i32)-455504775)); }
}
class K1 {
    u16 iv0;
    u16 iv1;
    u32 iv2;
    void init(void) { iv0 = 7300; iv1 = 34702; iv2 = 1059805917; }
    void setvals(u16 a0, u16 a1, u32 a2) { iv0 = a0; iv1 = a1; iv2 = a2; }
    i16 mix(void) { return (i16)(((i16)(iv0 - (u16)iv2) / ((i16)23940 | (i16)1))); }
}
class B0 {
    i8 b0;
    void init(void) { b0 = -6; }
    void setb(i8 a0) { b0 = a0; }
    i32 vget(void) { return (i32)((((i32)b0 >> ((i32)b0 & (i32)31)) | (i32)-204223178)); }
}
class D0_0 : B0 {
    void init(void) { b0 = -6; }
    i32 vget(void) { return (i32)((i32)-2065113332); }
}
class D0_1 : B0 {
    void init(void) { b0 = -6; }
    i32 vget(void) { return (i32)(((i32)(b0 + (u16)49732) / ((i32)-295728251 | (i32)1))); }
}
class B1 {
    i32 b0;
    void init(void) { b0 = -2083125848; }
    void setb(i32 a0) { b0 = a0; }
    u32 vget(void) { return (u32)((u32)b0); }
}
class D1_0 : B1 {
    void init(void) { b0 = -2083125848; }
    u32 vget(void) { return (u32)((((u32)1338685249 * (u32)177301322) - (u32)b0)); }
}
class D1_1 : B1 {
    void init(void) { b0 = -2083125848; }
    u32 vget(void) { return (u32)((u32)b0); }
}
u16 dc0;
class TC0 {
    u16 v;
    void init(void) { v = (u16)0; }
    void dealloc(void) { dc0 = dc0 + (u16)1; }
}
u16 dc1;
class TC1 {
    u16 v;
    TC0* kid;
    void init(void) { v = (u16)0; }
    void dealloc(void) { dc1 = dc1 + (u16)1; }
}
u16 churn(void) {
    TC1* tk0 = new TC1();
    tk0.kid = new TC0();
    TC0* tk1 = new TC0();
    TC0* tk2 = new TC0();
    return (u16)0;
}
u16 fn0(u16 p0, u16 p1, u16 p2) { g0 = (i8)((i8)p2); return (u16)(((u16)(g0 * (u8)179) % (((u16)53469 ^ (u16)p1) | (u16)1))); }
u8, u8 mr0(u8 p0, u8 p1, u8 p2) { return (u8)((u8)30), (u8)(p1); }
u32, u32 mr1(u32 p0) { return (u32)(p0), (u32)(p0); }

void main(void)
{
    g0 = (i8)(-73);
    dc0 = (u16)0;
    dc1 = (u16)0;
    i16 v0 = (i16)(((i16)25382 | ((i16)-23919 * (i16)-20158)));
    u32 v1 = (u32)(((u32)3612643547 << (((((u32)678400369 ^ (u32)3132866198) / (((u32)v0 & (u32)v0) | (u32)1)) % (((u32)3204232851 >> (((u32)3217630666 & (u32)v0) & (u32)31)) | (u32)1)) & (u32)31)));
    u32 v2 = (u32)(((u32)3194688760 >> ((u32)1381891547 & (u32)31)));
    i8 v3 = (i8)((i8)v2);
    for (i16 lc4 = (i16)0; lc4 < (i16)5; lc4 = lc4 + (i16)1) {
        for (i16 lc5 = (i16)0; lc5 < (i16)2; lc5 = lc5 + (i16)1) { v0 = (i16)(lc4); }
    }
    churn();
    churn();
    Stdio.printf("%lu %lu %lu %lu %lu %lu\n", (u32)(v0), (u32)(v1), (u32)(v2), (u32)(v3), (u32)(g0), (u32)(dc0));
    Stdio.printf("%lu\n", (u32)(dc1));
    return;
}
