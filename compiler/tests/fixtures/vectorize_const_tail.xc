// vectorize_const_tail.xc — CONSTANT trip counts that are not a whole number of
// vectors, which is what the vectoriser's epilogue exists for (#1124).
//
// Distinct from vectorize_var_trip.xc: these bounds are compile-time literals,
// so the vector portion and the remainder are both known at compile time. The
// other vectorise fixtures all count to a multiple of 4, which is exactly why
// the missing epilogue was invisible for so long — and why, when the epilogue
// landed, no differential compared it: not one file in the tree had a constant
// non-multiple trip for the two compilers to disagree about.
//
// Also pins the START of the induction variable. The recogniser used to read
// the loop's BOUND and assume the counter began at zero, so
//
//     for (i = 1; i < 64; i++)
//
// was accepted on `64 % 4 == 0` while its real trip count is 63 — the last
// vector read one element PAST the array, on every vectorising back end. The
// condition is (N - start) % vw, and `from1` below is the case that catches it.
#import "Stdio.xc"

u32 ga[64];

u32 s63(void)  { u32 s = (u32)0; for (u32 i = (u32)0; i < (u32)63; i = i + (u32)1) s = s + ga[i]; return s; }
u32 s7(void)   { u32 s = (u32)0; for (u32 i = (u32)0; i < (u32)7;  i = i + (u32)1) s = s + ga[i]; return s; }
u32 s5(void)   { u32 s = (u32)0; for (u32 i = (u32)0; i < (u32)5;  i = i + (u32)1) s = s + ga[i]; return s; }
u32 s64(void)  { u32 s = (u32)0; for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1) s = s + ga[i]; return s; }
u32 from1(void){ u32 s = (u32)0; for (u32 i = (u32)1; i < (u32)64; i = i + (u32)1) s = s + ga[i]; return s; }
u32 from2(void){ u32 s = (u32)0; for (u32 i = (u32)2; i < (u32)63; i = i + (u32)1) s = s + ga[i]; return s; }

void main(void)
{
    for (u32 i = (u32)0; i < (u32)64; i = i + (u32)1) ga[i] = i;
    Stdio.printf("s63=%ld\n",   s63());
    Stdio.printf("s7=%ld\n",    s7());
    Stdio.printf("s5=%ld\n",    s5());
    Stdio.printf("s64=%ld\n",   s64());
    Stdio.printf("from1=%ld\n", from1());
    Stdio.printf("from2=%ld\n", from2());
}
