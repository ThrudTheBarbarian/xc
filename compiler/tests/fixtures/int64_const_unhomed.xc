// int64_const_unhomed.xc — a 64-bit CONSTANT that does not fit a register home.
//
// Found by the differential fuzzer (seed 960291), and only at -O0/-O1: at -O2+
// the expression folds and the constant never reaches the back end.
//
// The arm64 Const emitter hardcoded `w16` as its scratch, and materialiseOperand
// picks its 32-bit path from the register NAME — so an unhomed u64 constant
// materialised only its low half, storeReg wrote four bytes where the value is
// eight, and the next 8-byte load pulled the top half out of frame garbage. The
// low word was right and the high word was not, which is why it survived any
// test that only checked a value fit in 32 bits.
//
// The register pressure is the point: a small program homes the constant in a
// register and is correct either way. That is why this fixture keeps the loops
// and the global arrays it was reduced to rather than shrinking further — they
// are what force the spill. `ga1[27..31]` are printed as a control: they must
// stay 55 57 59 61 63 whatever the 64-bit path does.
#import "Stdio.xc"
struct S1 { u64 f0; u16 f1; }
i32 g1;
i32 ga0[16];
i16 ga1[32];
class K0 {
}
class TC0 {
    u16 v;
}
TC0@ gca[3];
u16 gcafill(void) {
    for (i16 i = (i16)0; i < (i16)3; i = i + (i16)1) {
        gca[i] = new TC0();
    }
    u16 s = gca[0].v + gca[1].v + gca[2].v;
    return s;
}
void main(void)
{
    for (i16 gi0 = (i16)0; gi0 < (i16)16; gi0 = gi0 + (i16)1) { ga0[gi0] = (i32)(gi0 * (i16)1 + (i16)9); }
    for (i16 gi1 = (i16)0; gi1 < (i16)32; gi1 = gi1 + (i16)1) { ga1[gi1] = (i16)(gi1 * (i16)2 + (i16)1); }
    u16 v2 = gcafill();
    i32 v3 = (i32)(g1);
    i16 wc4 = (i16)0;
    while (wc4 < (i16)2) { v3 = (i32)((g1 - (i32)(-(v3)))); wc4 = wc4 + (i16)1; }
    u16 v6 = (u16)((u16)(((u32)3485401987 :> ((u32)2311573210 & (u32)31)) * (i64)3602296947891131815));
    u32 v8 = (u32)0;
    for (i16 lc7 = (i16)1; lc7 < (i16)18; lc7 = lc7 + (i16)2) { v8 = (u32)(v8 + (u32)ga1[lc7]); }
    u16 v10 = (u16)0;
    for (i16 lc9 = (i16)2; lc9 < (i16)12; lc9 = lc9 + (i16)2) { if (ga1[lc9] > (i16)-30876) { v10 = v10 + (u16)1; } }
    u16 v12 = (u16)0;
    for (i16 lc11 = (i16)3; lc11 < (i16)13; lc11 = lc11 + (i16)1) { if (ga0[lc11] > (i32)1946765004) { v12 = v12 + (u16)1; } }
    S1 sa13[3];
    sa13[0].f0 = (u64)((((u64)12850679611778674706 & (u64)908505498692558115) << ((u64)18188218555363544523 & (u64)63)));
    sa13[0].f1 = (u16)(((v2 / (v6 | (u16)1)) ^ (u16)55758));
    Stdio.printf("%lu %lu %lu %lu %lu %lu\n", (u32)(ga1[27]), (u32)(ga1[28]), (u32)(ga1[29]), (u32)(ga1[30]), (u32)(ga1[31]), (u32)((sa13[0].f0) >> (u64)32));
}
