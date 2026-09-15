// vectorize_map_tail.xc — MAP loops whose trip count is not a whole number of
// vectors, which is what the map epilogue exists for.
//
// vectorize_const_tail.xc covers the same ground for REDUCTIONS. Map is the
// commoner shape and was the last one still refusing a non-multiple trip: the
// recogniser bailed on `N % vw != 0`, so `for (i = 0; i < 63; i++) b[i] = ...`
// stayed entirely scalar while the 64 version vectorised.
//
// The load-bearing check here is not the sum — it is the SENTINEL. A map loop
// writes memory, so an epilogue that runs the vector body one iteration too far
// corrupts the element PAST the bound, which no sum over [0, N) can see. Each
// case leaves gb[N] at 777 and the test prints it.
#import "Stdio.xc"

u32 ga[64];
u32 gb[64];

void fill(void)
{
    for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1) { ga[i] = i; gb[i] = (u32)777; }
}

// A RUNTIME bound, so this checking loop stays scalar and cannot share a bug
// with the loops it is checking.
u32 sumTo(u32 n)
{
    u32 s = (u32)0;
    for (u32 i = (u32)0; i < n; i = i + (u32)1) s = s + gb[i];
    return s;
}

void main(void)
{
    // 63 = 15 vectors + 3.  sum of 2i for i in [0,63) = 2 * (62*63/2) = 3906
    fill();
    for (u32 i = (u32)0; i < (u32)63; i = i + (u32)1) gb[i] = ga[i] * (u32)2;
    Stdio.printf("s63=%ld tail63=%ld\n", sumTo((u32)63), gb[63]);

    // 7 = 1 vector + 3.  sum of (i+10) for i in [0,7) = 21 + 70 = 91
    fill();
    for (u32 i = (u32)0; i < (u32)7; i = i + (u32)1) gb[i] = ga[i] + (u32)10;
    Stdio.printf("s7=%ld tail7=%ld\n", sumTo((u32)7), gb[7]);

    // 5 = 1 vector + 1.  sum of 3i for i in [0,5) = 3 * 10 = 30
    fill();
    for (u32 i = (u32)0; i < (u32)5; i = i + (u32)1) gb[i] = ga[i] * (u32)3;
    Stdio.printf("s5=%ld tail5=%ld\n", sumTo((u32)5), gb[5]);

    // 3 is FEWER than one vector: no vector iteration is possible, so the loop
    // must stay scalar and still be right.  sum of 4i for i in [0,3) = 12
    fill();
    for (u32 i = (u32)0; i < (u32)3; i = i + (u32)1) gb[i] = ga[i] * (u32)4;
    Stdio.printf("s3=%ld tail3=%ld\n", sumTo((u32)3), gb[3]);

    // 64 = 16 vectors exactly: the no-epilogue path, unchanged.
    // sum of 2i for i in [0,64) = 2 * (63*64/2) = 4032
    fill();
    for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1) gb[i] = ga[i] * (u32)2;
    Stdio.printf("s64=%ld last64=%ld\n", sumTo((u32)64), gb[63]);
}
