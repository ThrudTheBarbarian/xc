//xtc-flags: target=arm64
// Four reductions over one loop, which accumulator distribution splits into
// four loops — and each split CLONES the loop, so every clone used to be named
// `<hdr>_rem` and the back end emitted the same label three or four times. The
// assembler refused the unit: `duplicate label ..._for_header_rem_pre`.
//
// It reached a released compiler because nothing exercised it: the reporting
// team could not reproduce it outside a 3000-line translation unit, and no
// fixture carried more than two accumulators in one loop. Four is the
// threshold here, over two i64 arrays with a global trip count.
//
// Before the fix this does not build at -O2 or -O3 (assembly is refused); the
// answers at -O0/-O1 were always right, because distribution is -O2 and above.
#use Stdio
i64 gA[256];
i64 gB[256];
u32 gN;
i64 pick(u32 i) { return gA[i] + gB[i]; }
i32 main(i32 argc, u8** argv)
{
    gN = (u32)256;
    for (u32 i = (u32)0; i < gN; i++) { gA[i] = (i64)(i * (u32)7); gB[i] = (i64)(i ^ (u32)33); }
    i64 xmin = gA[0]; i64 xmax = gA[0]; i64 ymin = gB[0]; i64 ymax = gB[0];
    for (u32 c = (u32)1; c < gN; c++)
        {
        if (gA[c] < xmin) xmin = gA[c];
        if (gA[c] > xmax) xmax = gA[c];
        if (gB[c] < ymin) ymin = gB[c];
        if (gB[c] > ymax) ymax = gB[c];
        }
    Stdio.printf("%lld %lld %lld %lld\n", xmin, xmax, ymin, ymax);
    return 0;
}
