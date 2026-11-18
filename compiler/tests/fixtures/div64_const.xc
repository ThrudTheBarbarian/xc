//xtc-na: xt6502 — the 64-bit divisions and their checks exceed the 6502 frame budget
// 64-bit division and remainder by constants (#309): magic-number
// multiplies (umulh/smulh on arm64, mul/imul on x86-64), checked against the
// same divisions by a value the compiler cannot see. Divisors: small, large,
// near +-2^63, negative; dividends: edges and a seeded random set.
#import "Stdio.xc"
i64 sq0(i64 x) { return x / (i64)3; }
i64 sr0(i64 x) { return x % (i64)3; }
i64 sq1(i64 x) { return x / (i64)5; }
i64 sr1(i64 x) { return x % (i64)5; }
i64 sq2(i64 x) { return x / (i64)6; }
i64 sr2(i64 x) { return x % (i64)6; }
i64 sq3(i64 x) { return x / (i64)7; }
i64 sr3(i64 x) { return x % (i64)7; }
i64 sq4(i64 x) { return x / (i64)9; }
i64 sr4(i64 x) { return x % (i64)9; }
i64 sq5(i64 x) { return x / (i64)10; }
i64 sr5(i64 x) { return x % (i64)10; }
i64 sq6(i64 x) { return x / (i64)11; }
i64 sr6(i64 x) { return x % (i64)11; }
i64 sq7(i64 x) { return x / (i64)12; }
i64 sr7(i64 x) { return x % (i64)12; }
i64 sq8(i64 x) { return x / (i64)13; }
i64 sr8(i64 x) { return x % (i64)13; }
i64 sq9(i64 x) { return x / (i64)25; }
i64 sr9(i64 x) { return x % (i64)25; }
i64 sq10(i64 x) { return x / (i64)60; }
i64 sr10(i64 x) { return x % (i64)60; }
i64 sq11(i64 x) { return x / (i64)100; }
i64 sr11(i64 x) { return x % (i64)100; }
i64 sq12(i64 x) { return x / (i64)641; }
i64 sr12(i64 x) { return x % (i64)641; }
i64 sq13(i64 x) { return x / (i64)1000; }
i64 sr13(i64 x) { return x % (i64)1000; }
i64 sq14(i64 x) { return x / (i64)6700417; }
i64 sr14(i64 x) { return x % (i64)6700417; }
i64 sq15(i64 x) { return x / (i64)1000000007; }
i64 sr15(i64 x) { return x % (i64)1000000007; }
i64 sq16(i64 x) { return x / (i64)2147483647; }
i64 sr16(i64 x) { return x % (i64)2147483647; }
i64 sq17(i64 x) { return x / (i64)2147483649; }
i64 sr17(i64 x) { return x % (i64)2147483649; }
i64 sq18(i64 x) { return x / (i64)4294967295; }
i64 sr18(i64 x) { return x % (i64)4294967295; }
i64 sq19(i64 x) { return x / (i64)4294967297; }
i64 sr19(i64 x) { return x % (i64)4294967297; }
i64 sq20(i64 x) { return x / (i64)1000000000039; }
i64 sr20(i64 x) { return x % (i64)1000000000039; }
i64 sq21(i64 x) { return x / (i64)4611686018427387905; }
i64 sr21(i64 x) { return x % (i64)4611686018427387905; }
i64 sq22(i64 x) { return x / (i64)9223372036854775807; }
i64 sr22(i64 x) { return x % (i64)9223372036854775807; }
i64 sq23(i64 x) { return x / (i64)9223372036854775783; }
i64 sr23(i64 x) { return x % (i64)9223372036854775783; }
i64 sq24(i64 x) { return x / (i64)-3; }
i64 sr24(i64 x) { return x % (i64)-3; }
i64 sq25(i64 x) { return x / (i64)-7; }
i64 sr25(i64 x) { return x % (i64)-7; }
i64 sq26(i64 x) { return x / (i64)-10; }
i64 sr26(i64 x) { return x % (i64)-10; }
i64 sq27(i64 x) { return x / (i64)-1000; }
i64 sr27(i64 x) { return x % (i64)-1000; }
i64 sq28(i64 x) { return x / (i64)-6700417; }
i64 sr28(i64 x) { return x % (i64)-6700417; }
i64 sq29(i64 x) { return x / (i64)-4611686018427387905; }
i64 sr29(i64 x) { return x % (i64)-4611686018427387905; }
i64 sq30(i64 x) { return x / (i64)-9223372036854775807; }
i64 sr30(i64 x) { return x % (i64)-9223372036854775807; }
u64 uq0(u64 x) { return x / (u64)3; }
u64 ur0(u64 x) { return x % (u64)3; }
u64 uq1(u64 x) { return x / (u64)5; }
u64 ur1(u64 x) { return x % (u64)5; }
u64 uq2(u64 x) { return x / (u64)6; }
u64 ur2(u64 x) { return x % (u64)6; }
u64 uq3(u64 x) { return x / (u64)7; }
u64 ur3(u64 x) { return x % (u64)7; }
u64 uq4(u64 x) { return x / (u64)9; }
u64 ur4(u64 x) { return x % (u64)9; }
u64 uq5(u64 x) { return x / (u64)10; }
u64 ur5(u64 x) { return x % (u64)10; }
u64 uq6(u64 x) { return x / (u64)11; }
u64 ur6(u64 x) { return x % (u64)11; }
u64 uq7(u64 x) { return x / (u64)12; }
u64 ur7(u64 x) { return x % (u64)12; }
u64 uq8(u64 x) { return x / (u64)13; }
u64 ur8(u64 x) { return x % (u64)13; }
u64 uq9(u64 x) { return x / (u64)25; }
u64 ur9(u64 x) { return x % (u64)25; }
u64 uq10(u64 x) { return x / (u64)60; }
u64 ur10(u64 x) { return x % (u64)60; }
u64 uq11(u64 x) { return x / (u64)100; }
u64 ur11(u64 x) { return x % (u64)100; }
u64 uq12(u64 x) { return x / (u64)641; }
u64 ur12(u64 x) { return x % (u64)641; }
u64 uq13(u64 x) { return x / (u64)1000; }
u64 ur13(u64 x) { return x % (u64)1000; }
u64 uq14(u64 x) { return x / (u64)6700417; }
u64 ur14(u64 x) { return x % (u64)6700417; }
u64 uq15(u64 x) { return x / (u64)1000000007; }
u64 ur15(u64 x) { return x % (u64)1000000007; }
u64 uq16(u64 x) { return x / (u64)2147483647; }
u64 ur16(u64 x) { return x % (u64)2147483647; }
u64 uq17(u64 x) { return x / (u64)2147483649; }
u64 ur17(u64 x) { return x % (u64)2147483649; }
u64 uq18(u64 x) { return x / (u64)4294967295; }
u64 ur18(u64 x) { return x % (u64)4294967295; }
u64 uq19(u64 x) { return x / (u64)4294967297; }
u64 ur19(u64 x) { return x % (u64)4294967297; }
u64 uq20(u64 x) { return x / (u64)1000000000039; }
u64 ur20(u64 x) { return x % (u64)1000000000039; }
u64 uq21(u64 x) { return x / (u64)4611686018427387905; }
u64 ur21(u64 x) { return x % (u64)4611686018427387905; }
u64 uq22(u64 x) { return x / (u64)9223372036854775807; }
u64 ur22(u64 x) { return x % (u64)9223372036854775807; }
u64 uq23(u64 x) { return x / (u64)9223372036854775783; }
u64 ur23(u64 x) { return x % (u64)9223372036854775783; }
u64 uq24(u64 x) { return x / (u64)3298534883329; }
u64 ur24(u64 x) { return x % (u64)3298534883329; }
u64 uq25(u64 x) { return x / (u64)2305843009213693951; }
u64 ur25(u64 x) { return x % (u64)2305843009213693951; }
i32 main(i32 argc, u8** argv)
    {
    u64 bad = (u64)0; u64 n = (u64)0;
    i64 one = (i64)argc;
    i64 xs[112];
    xs[0] = (i64)0; xs[1] = (i64)0 - (i64)0 - one + (i64)1;
    xs[2] = (i64)1; xs[3] = (i64)0 - (i64)1 - one + (i64)1;
    xs[4] = (i64)2; xs[5] = (i64)0 - (i64)2 - one + (i64)1;
    xs[6] = (i64)3; xs[7] = (i64)0 - (i64)3 - one + (i64)1;
    xs[8] = (i64)7; xs[9] = (i64)0 - (i64)7 - one + (i64)1;
    xs[10] = (i64)100; xs[11] = (i64)0 - (i64)100 - one + (i64)1;
    xs[12] = (i64)1000000000; xs[13] = (i64)0 - (i64)1000000000 - one + (i64)1;
    xs[14] = (i64)2147483647; xs[15] = (i64)0 - (i64)2147483647 - one + (i64)1;
    xs[16] = (i64)2147483648; xs[17] = (i64)0 - (i64)2147483648 - one + (i64)1;
    xs[18] = (i64)4294967295; xs[19] = (i64)0 - (i64)4294967295 - one + (i64)1;
    xs[20] = (i64)4294967296; xs[21] = (i64)0 - (i64)4294967296 - one + (i64)1;
    xs[22] = (i64)4294967297; xs[23] = (i64)0 - (i64)4294967297 - one + (i64)1;
    xs[24] = (i64)1099511627781; xs[25] = (i64)0 - (i64)1099511627781 - one + (i64)1;
    xs[26] = (i64)4611686018427387904; xs[27] = (i64)0 - (i64)4611686018427387904 - one + (i64)1;
    xs[28] = (i64)9223372036854775807; xs[29] = (i64)0 - (i64)9223372036854775807 - one + (i64)1;
    xs[30] = (i64)9223372036854775806; xs[31] = (i64)0 - (i64)9223372036854775806 - one + (i64)1;
    xs[32] = (i64)5482724546177801743; xs[33] = (i64)0 - (i64)5482724546177801743 - one + (i64)1;
    xs[34] = (i64)2450653007035755023; xs[35] = (i64)0 - (i64)2450653007035755023 - one + (i64)1;
    xs[36] = (i64)4402020557995403254; xs[37] = (i64)0 - (i64)4402020557995403254 - one + (i64)1;
    xs[38] = (i64)4257497525442430461; xs[39] = (i64)0 - (i64)4257497525442430461 - one + (i64)1;
    xs[40] = (i64)1143326648582981116; xs[41] = (i64)0 - (i64)1143326648582981116 - one + (i64)1;
    xs[42] = (i64)4864118993118482810; xs[43] = (i64)0 - (i64)4864118993118482810 - one + (i64)1;
    xs[44] = (i64)89596820588777886; xs[45] = (i64)0 - (i64)89596820588777886 - one + (i64)1;
    xs[46] = (i64)4062323501322953874; xs[47] = (i64)0 - (i64)4062323501322953874 - one + (i64)1;
    xs[48] = (i64)5845217651461577163; xs[49] = (i64)0 - (i64)5845217651461577163 - one + (i64)1;
    xs[50] = (i64)4804047600736021034; xs[51] = (i64)0 - (i64)4804047600736021034 - one + (i64)1;
    xs[52] = (i64)4574018562547680592; xs[53] = (i64)0 - (i64)4574018562547680592 - one + (i64)1;
    xs[54] = (i64)3057503253591194906; xs[55] = (i64)0 - (i64)3057503253591194906 - one + (i64)1;
    xs[56] = (i64)2296729832322529357; xs[57] = (i64)0 - (i64)2296729832322529357 - one + (i64)1;
    xs[58] = (i64)7215529236597382830; xs[59] = (i64)0 - (i64)7215529236597382830 - one + (i64)1;
    xs[60] = (i64)7706942354188457267; xs[61] = (i64)0 - (i64)7706942354188457267 - one + (i64)1;
    xs[62] = (i64)6674146593420126317; xs[63] = (i64)0 - (i64)6674146593420126317 - one + (i64)1;
    xs[64] = (i64)4167181038575956730; xs[65] = (i64)0 - (i64)4167181038575956730 - one + (i64)1;
    xs[66] = (i64)856795090140933553; xs[67] = (i64)0 - (i64)856795090140933553 - one + (i64)1;
    xs[68] = (i64)6463311023866072395; xs[69] = (i64)0 - (i64)6463311023866072395 - one + (i64)1;
    xs[70] = (i64)1894208969108519494; xs[71] = (i64)0 - (i64)1894208969108519494 - one + (i64)1;
    xs[72] = (i64)4704574536933085739; xs[73] = (i64)0 - (i64)4704574536933085739 - one + (i64)1;
    xs[74] = (i64)933255526928419395; xs[75] = (i64)0 - (i64)933255526928419395 - one + (i64)1;
    xs[76] = (i64)7709120093361998856; xs[77] = (i64)0 - (i64)7709120093361998856 - one + (i64)1;
    xs[78] = (i64)7367786151901133004; xs[79] = (i64)0 - (i64)7367786151901133004 - one + (i64)1;
    xs[80] = (i64)1447653279724575077; xs[81] = (i64)0 - (i64)1447653279724575077 - one + (i64)1;
    xs[82] = (i64)5594861519783477393; xs[83] = (i64)0 - (i64)5594861519783477393 - one + (i64)1;
    xs[84] = (i64)6820809502293801654; xs[85] = (i64)0 - (i64)6820809502293801654 - one + (i64)1;
    xs[86] = (i64)1862359161593698644; xs[87] = (i64)0 - (i64)1862359161593698644 - one + (i64)1;
    xs[88] = (i64)6273894051991256411; xs[89] = (i64)0 - (i64)6273894051991256411 - one + (i64)1;
    xs[90] = (i64)698469820821579859; xs[91] = (i64)0 - (i64)698469820821579859 - one + (i64)1;
    xs[92] = (i64)3908257024590989209; xs[93] = (i64)0 - (i64)3908257024590989209 - one + (i64)1;
    xs[94] = (i64)5593566643845285662; xs[95] = (i64)0 - (i64)5593566643845285662 - one + (i64)1;
    xs[96] = (i64)2483026649785076168; xs[97] = (i64)0 - (i64)2483026649785076168 - one + (i64)1;
    xs[98] = (i64)7164123817527816060; xs[99] = (i64)0 - (i64)7164123817527816060 - one + (i64)1;
    xs[100] = (i64)2743233613054177121; xs[101] = (i64)0 - (i64)2743233613054177121 - one + (i64)1;
    xs[102] = (i64)4312739038793464176; xs[103] = (i64)0 - (i64)4312739038793464176 - one + (i64)1;
    xs[104] = (i64)2159798888097141438; xs[105] = (i64)0 - (i64)2159798888097141438 - one + (i64)1;
    xs[106] = (i64)5037641201227399569; xs[107] = (i64)0 - (i64)5037641201227399569 - one + (i64)1;
    xs[108] = (i64)2039249110650202463; xs[109] = (i64)0 - (i64)2039249110650202463 - one + (i64)1;
    xs[110] = (i64)1271227342744107706; xs[111] = (i64)0 - (i64)1271227342744107706 - one + (i64)1;
    for (u32 k = (u32)0; k < (u32)112; k = k + (u32)1)
        {
        i64 x = xs[k]; u64 ux = (u64)x;
        { i64 dv = (i64)3 * one; n = n + (u64)2; if (sq0(x) != x / dv) bad = bad + (u64)1; if (sr0(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)5 * one; n = n + (u64)2; if (sq1(x) != x / dv) bad = bad + (u64)1; if (sr1(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)6 * one; n = n + (u64)2; if (sq2(x) != x / dv) bad = bad + (u64)1; if (sr2(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)7 * one; n = n + (u64)2; if (sq3(x) != x / dv) bad = bad + (u64)1; if (sr3(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)9 * one; n = n + (u64)2; if (sq4(x) != x / dv) bad = bad + (u64)1; if (sr4(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)10 * one; n = n + (u64)2; if (sq5(x) != x / dv) bad = bad + (u64)1; if (sr5(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)11 * one; n = n + (u64)2; if (sq6(x) != x / dv) bad = bad + (u64)1; if (sr6(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)12 * one; n = n + (u64)2; if (sq7(x) != x / dv) bad = bad + (u64)1; if (sr7(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)13 * one; n = n + (u64)2; if (sq8(x) != x / dv) bad = bad + (u64)1; if (sr8(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)25 * one; n = n + (u64)2; if (sq9(x) != x / dv) bad = bad + (u64)1; if (sr9(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)60 * one; n = n + (u64)2; if (sq10(x) != x / dv) bad = bad + (u64)1; if (sr10(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)100 * one; n = n + (u64)2; if (sq11(x) != x / dv) bad = bad + (u64)1; if (sr11(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)641 * one; n = n + (u64)2; if (sq12(x) != x / dv) bad = bad + (u64)1; if (sr12(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)1000 * one; n = n + (u64)2; if (sq13(x) != x / dv) bad = bad + (u64)1; if (sr13(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)6700417 * one; n = n + (u64)2; if (sq14(x) != x / dv) bad = bad + (u64)1; if (sr14(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)1000000007 * one; n = n + (u64)2; if (sq15(x) != x / dv) bad = bad + (u64)1; if (sr15(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)2147483647 * one; n = n + (u64)2; if (sq16(x) != x / dv) bad = bad + (u64)1; if (sr16(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)2147483649 * one; n = n + (u64)2; if (sq17(x) != x / dv) bad = bad + (u64)1; if (sr17(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)4294967295 * one; n = n + (u64)2; if (sq18(x) != x / dv) bad = bad + (u64)1; if (sr18(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)4294967297 * one; n = n + (u64)2; if (sq19(x) != x / dv) bad = bad + (u64)1; if (sr19(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)1000000000039 * one; n = n + (u64)2; if (sq20(x) != x / dv) bad = bad + (u64)1; if (sr20(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)4611686018427387905 * one; n = n + (u64)2; if (sq21(x) != x / dv) bad = bad + (u64)1; if (sr21(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)9223372036854775807 * one; n = n + (u64)2; if (sq22(x) != x / dv) bad = bad + (u64)1; if (sr22(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)9223372036854775783 * one; n = n + (u64)2; if (sq23(x) != x / dv) bad = bad + (u64)1; if (sr23(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)-3 * one; n = n + (u64)2; if (sq24(x) != x / dv) bad = bad + (u64)1; if (sr24(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)-7 * one; n = n + (u64)2; if (sq25(x) != x / dv) bad = bad + (u64)1; if (sr25(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)-10 * one; n = n + (u64)2; if (sq26(x) != x / dv) bad = bad + (u64)1; if (sr26(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)-1000 * one; n = n + (u64)2; if (sq27(x) != x / dv) bad = bad + (u64)1; if (sr27(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)-6700417 * one; n = n + (u64)2; if (sq28(x) != x / dv) bad = bad + (u64)1; if (sr28(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)-4611686018427387905 * one; n = n + (u64)2; if (sq29(x) != x / dv) bad = bad + (u64)1; if (sr29(x) != x % dv) bad = bad + (u64)1; }
        { i64 dv = (i64)-9223372036854775807 * one; n = n + (u64)2; if (sq30(x) != x / dv) bad = bad + (u64)1; if (sr30(x) != x % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)3 * (u64)one; n = n + (u64)2; if (uq0(ux) != ux / dv) bad = bad + (u64)1; if (ur0(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)5 * (u64)one; n = n + (u64)2; if (uq1(ux) != ux / dv) bad = bad + (u64)1; if (ur1(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)6 * (u64)one; n = n + (u64)2; if (uq2(ux) != ux / dv) bad = bad + (u64)1; if (ur2(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)7 * (u64)one; n = n + (u64)2; if (uq3(ux) != ux / dv) bad = bad + (u64)1; if (ur3(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)9 * (u64)one; n = n + (u64)2; if (uq4(ux) != ux / dv) bad = bad + (u64)1; if (ur4(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)10 * (u64)one; n = n + (u64)2; if (uq5(ux) != ux / dv) bad = bad + (u64)1; if (ur5(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)11 * (u64)one; n = n + (u64)2; if (uq6(ux) != ux / dv) bad = bad + (u64)1; if (ur6(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)12 * (u64)one; n = n + (u64)2; if (uq7(ux) != ux / dv) bad = bad + (u64)1; if (ur7(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)13 * (u64)one; n = n + (u64)2; if (uq8(ux) != ux / dv) bad = bad + (u64)1; if (ur8(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)25 * (u64)one; n = n + (u64)2; if (uq9(ux) != ux / dv) bad = bad + (u64)1; if (ur9(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)60 * (u64)one; n = n + (u64)2; if (uq10(ux) != ux / dv) bad = bad + (u64)1; if (ur10(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)100 * (u64)one; n = n + (u64)2; if (uq11(ux) != ux / dv) bad = bad + (u64)1; if (ur11(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)641 * (u64)one; n = n + (u64)2; if (uq12(ux) != ux / dv) bad = bad + (u64)1; if (ur12(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)1000 * (u64)one; n = n + (u64)2; if (uq13(ux) != ux / dv) bad = bad + (u64)1; if (ur13(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)6700417 * (u64)one; n = n + (u64)2; if (uq14(ux) != ux / dv) bad = bad + (u64)1; if (ur14(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)1000000007 * (u64)one; n = n + (u64)2; if (uq15(ux) != ux / dv) bad = bad + (u64)1; if (ur15(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)2147483647 * (u64)one; n = n + (u64)2; if (uq16(ux) != ux / dv) bad = bad + (u64)1; if (ur16(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)2147483649 * (u64)one; n = n + (u64)2; if (uq17(ux) != ux / dv) bad = bad + (u64)1; if (ur17(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)4294967295 * (u64)one; n = n + (u64)2; if (uq18(ux) != ux / dv) bad = bad + (u64)1; if (ur18(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)4294967297 * (u64)one; n = n + (u64)2; if (uq19(ux) != ux / dv) bad = bad + (u64)1; if (ur19(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)1000000000039 * (u64)one; n = n + (u64)2; if (uq20(ux) != ux / dv) bad = bad + (u64)1; if (ur20(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)4611686018427387905 * (u64)one; n = n + (u64)2; if (uq21(ux) != ux / dv) bad = bad + (u64)1; if (ur21(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)9223372036854775807 * (u64)one; n = n + (u64)2; if (uq22(ux) != ux / dv) bad = bad + (u64)1; if (ur22(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)9223372036854775783 * (u64)one; n = n + (u64)2; if (uq23(ux) != ux / dv) bad = bad + (u64)1; if (ur23(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)3298534883329 * (u64)one; n = n + (u64)2; if (uq24(ux) != ux / dv) bad = bad + (u64)1; if (ur24(ux) != ux % dv) bad = bad + (u64)1; }
        { u64 dv = (u64)2305843009213693951 * (u64)one; n = n + (u64)2; if (uq25(ux) != ux / dv) bad = bad + (u64)1; if (ur25(ux) != ux % dv) bad = bad + (u64)1; }
        }
    Stdio.printf("checked %llu bad %llu\n", n, bad);
    return 0;
    }
