//xtc-na: xt6502 — seventy loops in one function exceed the 6502 frame budget
// Seventy independent pointer-walk loops in one function: the pointer-IV
// pass rewrites one loop per round under a cap of 64 rounds, so it stops
// at the cap with loops left (#334). XC_OPT_CAPS=1 reports that; the
// result is the same either way.
#import "Stdio.xc"
u32 walk(u32* a, u32 n)
    {
    u32 s = (u32)0;
    for (u32 k0 = (u32)0; k0 < n; k0 = k0 + (u32)1)
        s = s + a[k0] * (u32)1;
    for (u32 k1 = (u32)0; k1 < n; k1 = k1 + (u32)1)
        s = s + a[k1] * (u32)2;
    for (u32 k2 = (u32)0; k2 < n; k2 = k2 + (u32)1)
        s = s + a[k2] * (u32)3;
    for (u32 k3 = (u32)0; k3 < n; k3 = k3 + (u32)1)
        s = s + a[k3] * (u32)4;
    for (u32 k4 = (u32)0; k4 < n; k4 = k4 + (u32)1)
        s = s + a[k4] * (u32)5;
    for (u32 k5 = (u32)0; k5 < n; k5 = k5 + (u32)1)
        s = s + a[k5] * (u32)6;
    for (u32 k6 = (u32)0; k6 < n; k6 = k6 + (u32)1)
        s = s + a[k6] * (u32)7;
    for (u32 k7 = (u32)0; k7 < n; k7 = k7 + (u32)1)
        s = s + a[k7] * (u32)8;
    for (u32 k8 = (u32)0; k8 < n; k8 = k8 + (u32)1)
        s = s + a[k8] * (u32)9;
    for (u32 k9 = (u32)0; k9 < n; k9 = k9 + (u32)1)
        s = s + a[k9] * (u32)10;
    for (u32 k10 = (u32)0; k10 < n; k10 = k10 + (u32)1)
        s = s + a[k10] * (u32)11;
    for (u32 k11 = (u32)0; k11 < n; k11 = k11 + (u32)1)
        s = s + a[k11] * (u32)12;
    for (u32 k12 = (u32)0; k12 < n; k12 = k12 + (u32)1)
        s = s + a[k12] * (u32)13;
    for (u32 k13 = (u32)0; k13 < n; k13 = k13 + (u32)1)
        s = s + a[k13] * (u32)14;
    for (u32 k14 = (u32)0; k14 < n; k14 = k14 + (u32)1)
        s = s + a[k14] * (u32)15;
    for (u32 k15 = (u32)0; k15 < n; k15 = k15 + (u32)1)
        s = s + a[k15] * (u32)16;
    for (u32 k16 = (u32)0; k16 < n; k16 = k16 + (u32)1)
        s = s + a[k16] * (u32)17;
    for (u32 k17 = (u32)0; k17 < n; k17 = k17 + (u32)1)
        s = s + a[k17] * (u32)18;
    for (u32 k18 = (u32)0; k18 < n; k18 = k18 + (u32)1)
        s = s + a[k18] * (u32)19;
    for (u32 k19 = (u32)0; k19 < n; k19 = k19 + (u32)1)
        s = s + a[k19] * (u32)20;
    for (u32 k20 = (u32)0; k20 < n; k20 = k20 + (u32)1)
        s = s + a[k20] * (u32)21;
    for (u32 k21 = (u32)0; k21 < n; k21 = k21 + (u32)1)
        s = s + a[k21] * (u32)22;
    for (u32 k22 = (u32)0; k22 < n; k22 = k22 + (u32)1)
        s = s + a[k22] * (u32)23;
    for (u32 k23 = (u32)0; k23 < n; k23 = k23 + (u32)1)
        s = s + a[k23] * (u32)24;
    for (u32 k24 = (u32)0; k24 < n; k24 = k24 + (u32)1)
        s = s + a[k24] * (u32)25;
    for (u32 k25 = (u32)0; k25 < n; k25 = k25 + (u32)1)
        s = s + a[k25] * (u32)26;
    for (u32 k26 = (u32)0; k26 < n; k26 = k26 + (u32)1)
        s = s + a[k26] * (u32)27;
    for (u32 k27 = (u32)0; k27 < n; k27 = k27 + (u32)1)
        s = s + a[k27] * (u32)28;
    for (u32 k28 = (u32)0; k28 < n; k28 = k28 + (u32)1)
        s = s + a[k28] * (u32)29;
    for (u32 k29 = (u32)0; k29 < n; k29 = k29 + (u32)1)
        s = s + a[k29] * (u32)30;
    for (u32 k30 = (u32)0; k30 < n; k30 = k30 + (u32)1)
        s = s + a[k30] * (u32)31;
    for (u32 k31 = (u32)0; k31 < n; k31 = k31 + (u32)1)
        s = s + a[k31] * (u32)32;
    for (u32 k32 = (u32)0; k32 < n; k32 = k32 + (u32)1)
        s = s + a[k32] * (u32)33;
    for (u32 k33 = (u32)0; k33 < n; k33 = k33 + (u32)1)
        s = s + a[k33] * (u32)34;
    for (u32 k34 = (u32)0; k34 < n; k34 = k34 + (u32)1)
        s = s + a[k34] * (u32)35;
    for (u32 k35 = (u32)0; k35 < n; k35 = k35 + (u32)1)
        s = s + a[k35] * (u32)36;
    for (u32 k36 = (u32)0; k36 < n; k36 = k36 + (u32)1)
        s = s + a[k36] * (u32)37;
    for (u32 k37 = (u32)0; k37 < n; k37 = k37 + (u32)1)
        s = s + a[k37] * (u32)38;
    for (u32 k38 = (u32)0; k38 < n; k38 = k38 + (u32)1)
        s = s + a[k38] * (u32)39;
    for (u32 k39 = (u32)0; k39 < n; k39 = k39 + (u32)1)
        s = s + a[k39] * (u32)40;
    for (u32 k40 = (u32)0; k40 < n; k40 = k40 + (u32)1)
        s = s + a[k40] * (u32)41;
    for (u32 k41 = (u32)0; k41 < n; k41 = k41 + (u32)1)
        s = s + a[k41] * (u32)42;
    for (u32 k42 = (u32)0; k42 < n; k42 = k42 + (u32)1)
        s = s + a[k42] * (u32)43;
    for (u32 k43 = (u32)0; k43 < n; k43 = k43 + (u32)1)
        s = s + a[k43] * (u32)44;
    for (u32 k44 = (u32)0; k44 < n; k44 = k44 + (u32)1)
        s = s + a[k44] * (u32)45;
    for (u32 k45 = (u32)0; k45 < n; k45 = k45 + (u32)1)
        s = s + a[k45] * (u32)46;
    for (u32 k46 = (u32)0; k46 < n; k46 = k46 + (u32)1)
        s = s + a[k46] * (u32)47;
    for (u32 k47 = (u32)0; k47 < n; k47 = k47 + (u32)1)
        s = s + a[k47] * (u32)48;
    for (u32 k48 = (u32)0; k48 < n; k48 = k48 + (u32)1)
        s = s + a[k48] * (u32)49;
    for (u32 k49 = (u32)0; k49 < n; k49 = k49 + (u32)1)
        s = s + a[k49] * (u32)50;
    for (u32 k50 = (u32)0; k50 < n; k50 = k50 + (u32)1)
        s = s + a[k50] * (u32)51;
    for (u32 k51 = (u32)0; k51 < n; k51 = k51 + (u32)1)
        s = s + a[k51] * (u32)52;
    for (u32 k52 = (u32)0; k52 < n; k52 = k52 + (u32)1)
        s = s + a[k52] * (u32)53;
    for (u32 k53 = (u32)0; k53 < n; k53 = k53 + (u32)1)
        s = s + a[k53] * (u32)54;
    for (u32 k54 = (u32)0; k54 < n; k54 = k54 + (u32)1)
        s = s + a[k54] * (u32)55;
    for (u32 k55 = (u32)0; k55 < n; k55 = k55 + (u32)1)
        s = s + a[k55] * (u32)56;
    for (u32 k56 = (u32)0; k56 < n; k56 = k56 + (u32)1)
        s = s + a[k56] * (u32)57;
    for (u32 k57 = (u32)0; k57 < n; k57 = k57 + (u32)1)
        s = s + a[k57] * (u32)58;
    for (u32 k58 = (u32)0; k58 < n; k58 = k58 + (u32)1)
        s = s + a[k58] * (u32)59;
    for (u32 k59 = (u32)0; k59 < n; k59 = k59 + (u32)1)
        s = s + a[k59] * (u32)60;
    for (u32 k60 = (u32)0; k60 < n; k60 = k60 + (u32)1)
        s = s + a[k60] * (u32)61;
    for (u32 k61 = (u32)0; k61 < n; k61 = k61 + (u32)1)
        s = s + a[k61] * (u32)62;
    for (u32 k62 = (u32)0; k62 < n; k62 = k62 + (u32)1)
        s = s + a[k62] * (u32)63;
    for (u32 k63 = (u32)0; k63 < n; k63 = k63 + (u32)1)
        s = s + a[k63] * (u32)64;
    for (u32 k64 = (u32)0; k64 < n; k64 = k64 + (u32)1)
        s = s + a[k64] * (u32)65;
    for (u32 k65 = (u32)0; k65 < n; k65 = k65 + (u32)1)
        s = s + a[k65] * (u32)66;
    for (u32 k66 = (u32)0; k66 < n; k66 = k66 + (u32)1)
        s = s + a[k66] * (u32)67;
    for (u32 k67 = (u32)0; k67 < n; k67 = k67 + (u32)1)
        s = s + a[k67] * (u32)68;
    for (u32 k68 = (u32)0; k68 < n; k68 = k68 + (u32)1)
        s = s + a[k68] * (u32)69;
    for (u32 k69 = (u32)0; k69 < n; k69 = k69 + (u32)1)
        s = s + a[k69] * (u32)70;
    return s;
    }
i32 main(i32 argc, u8** argv)
    {
    u32 a[16];
    for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
        a[i] = i + (u32)(argc > 99 ? argc : 1);   // as argc 1, on every target (argc is 0 on some)
    Stdio.printf("%u\n", walk(&a[0], (u32)16));
    return 0;
    }
