//xtc-na: xt6502 — forty loops in one function exceed the 6502 frame budget
// Forty loops in one function, each with an invariant product to hoist.
// LICM moved one loop's invariants per round under a cap of 32 rounds, so
// the loops past the 32nd kept their products inside (#334; XC_OPT_CAPS=1
// reported the cap). A round now visits every loop. The answer is the
// same either way.
#import "Stdio.xc"
u32 walk(u32* a, u32 n, u32 x, u32 y)
    {
    u32 s = (u32)0;
    for (u32 k0 = (u32)0; k0 < n; k0 = k0 + (u32)1)
        s = s + a[k0] * (x * y + (u32)1);
    for (u32 k1 = (u32)0; k1 < n; k1 = k1 + (u32)1)
        s = s + a[k1] * (x * y + (u32)2);
    for (u32 k2 = (u32)0; k2 < n; k2 = k2 + (u32)1)
        s = s + a[k2] * (x * y + (u32)3);
    for (u32 k3 = (u32)0; k3 < n; k3 = k3 + (u32)1)
        s = s + a[k3] * (x * y + (u32)4);
    for (u32 k4 = (u32)0; k4 < n; k4 = k4 + (u32)1)
        s = s + a[k4] * (x * y + (u32)5);
    for (u32 k5 = (u32)0; k5 < n; k5 = k5 + (u32)1)
        s = s + a[k5] * (x * y + (u32)6);
    for (u32 k6 = (u32)0; k6 < n; k6 = k6 + (u32)1)
        s = s + a[k6] * (x * y + (u32)7);
    for (u32 k7 = (u32)0; k7 < n; k7 = k7 + (u32)1)
        s = s + a[k7] * (x * y + (u32)8);
    for (u32 k8 = (u32)0; k8 < n; k8 = k8 + (u32)1)
        s = s + a[k8] * (x * y + (u32)9);
    for (u32 k9 = (u32)0; k9 < n; k9 = k9 + (u32)1)
        s = s + a[k9] * (x * y + (u32)10);
    for (u32 k10 = (u32)0; k10 < n; k10 = k10 + (u32)1)
        s = s + a[k10] * (x * y + (u32)11);
    for (u32 k11 = (u32)0; k11 < n; k11 = k11 + (u32)1)
        s = s + a[k11] * (x * y + (u32)12);
    for (u32 k12 = (u32)0; k12 < n; k12 = k12 + (u32)1)
        s = s + a[k12] * (x * y + (u32)13);
    for (u32 k13 = (u32)0; k13 < n; k13 = k13 + (u32)1)
        s = s + a[k13] * (x * y + (u32)14);
    for (u32 k14 = (u32)0; k14 < n; k14 = k14 + (u32)1)
        s = s + a[k14] * (x * y + (u32)15);
    for (u32 k15 = (u32)0; k15 < n; k15 = k15 + (u32)1)
        s = s + a[k15] * (x * y + (u32)16);
    for (u32 k16 = (u32)0; k16 < n; k16 = k16 + (u32)1)
        s = s + a[k16] * (x * y + (u32)17);
    for (u32 k17 = (u32)0; k17 < n; k17 = k17 + (u32)1)
        s = s + a[k17] * (x * y + (u32)18);
    for (u32 k18 = (u32)0; k18 < n; k18 = k18 + (u32)1)
        s = s + a[k18] * (x * y + (u32)19);
    for (u32 k19 = (u32)0; k19 < n; k19 = k19 + (u32)1)
        s = s + a[k19] * (x * y + (u32)20);
    for (u32 k20 = (u32)0; k20 < n; k20 = k20 + (u32)1)
        s = s + a[k20] * (x * y + (u32)21);
    for (u32 k21 = (u32)0; k21 < n; k21 = k21 + (u32)1)
        s = s + a[k21] * (x * y + (u32)22);
    for (u32 k22 = (u32)0; k22 < n; k22 = k22 + (u32)1)
        s = s + a[k22] * (x * y + (u32)23);
    for (u32 k23 = (u32)0; k23 < n; k23 = k23 + (u32)1)
        s = s + a[k23] * (x * y + (u32)24);
    for (u32 k24 = (u32)0; k24 < n; k24 = k24 + (u32)1)
        s = s + a[k24] * (x * y + (u32)25);
    for (u32 k25 = (u32)0; k25 < n; k25 = k25 + (u32)1)
        s = s + a[k25] * (x * y + (u32)26);
    for (u32 k26 = (u32)0; k26 < n; k26 = k26 + (u32)1)
        s = s + a[k26] * (x * y + (u32)27);
    for (u32 k27 = (u32)0; k27 < n; k27 = k27 + (u32)1)
        s = s + a[k27] * (x * y + (u32)28);
    for (u32 k28 = (u32)0; k28 < n; k28 = k28 + (u32)1)
        s = s + a[k28] * (x * y + (u32)29);
    for (u32 k29 = (u32)0; k29 < n; k29 = k29 + (u32)1)
        s = s + a[k29] * (x * y + (u32)30);
    for (u32 k30 = (u32)0; k30 < n; k30 = k30 + (u32)1)
        s = s + a[k30] * (x * y + (u32)31);
    for (u32 k31 = (u32)0; k31 < n; k31 = k31 + (u32)1)
        s = s + a[k31] * (x * y + (u32)32);
    for (u32 k32 = (u32)0; k32 < n; k32 = k32 + (u32)1)
        s = s + a[k32] * (x * y + (u32)33);
    for (u32 k33 = (u32)0; k33 < n; k33 = k33 + (u32)1)
        s = s + a[k33] * (x * y + (u32)34);
    for (u32 k34 = (u32)0; k34 < n; k34 = k34 + (u32)1)
        s = s + a[k34] * (x * y + (u32)35);
    for (u32 k35 = (u32)0; k35 < n; k35 = k35 + (u32)1)
        s = s + a[k35] * (x * y + (u32)36);
    for (u32 k36 = (u32)0; k36 < n; k36 = k36 + (u32)1)
        s = s + a[k36] * (x * y + (u32)37);
    for (u32 k37 = (u32)0; k37 < n; k37 = k37 + (u32)1)
        s = s + a[k37] * (x * y + (u32)38);
    for (u32 k38 = (u32)0; k38 < n; k38 = k38 + (u32)1)
        s = s + a[k38] * (x * y + (u32)39);
    for (u32 k39 = (u32)0; k39 < n; k39 = k39 + (u32)1)
        s = s + a[k39] * (x * y + (u32)40);
    return s;
    }

i32 main(void)
    {
    u32 n = (u32)50;
    u32* a = new u32[n];
    for (u32 i = (u32)0; i < n; i = i + (u32)1)
        a[i] = i;
    Stdio.printf("%u\n", walk(a, n, (u32)3, (u32)7));
    return 0;
    }
