// incdec_in_subscript.xc — `a[i++]`, where the step hides in the INDEX.
//
// The loop header needs a phi for `i`, and the scan that decides which locals
// get one enumerated the node kinds it descends into. An assignment added the
// name on its left and stopped, so a ++ inside the subscript on either side
// was never seen: `out[cnt++] = v` froze cnt at its entry value, wrote every
// element to out[0] and returned 0, and `sum += src[a++]` never terminated.
// private:docs/bugs/241. Sentinels are asymmetric so a coincidence cannot pass.
#import "Stdio.xc"

i32 gOut[8];
i32 gSrc[8];
i32 gPre[8];

u32 fill(i32 base)
{
    u32 cnt = (u32)0; u32 w = (u32)0;
    while (w < (u32)4) { gOut[cnt++] = base + (i32)w; w++; }
    return cnt;
}

void main()
{
    u32 n = fill((i32)100);
    Stdio.printf("n=%d out=%d,%d,%d,%d\n", n, gOut[0], gOut[1], gOut[2], gOut[3]);

    // The same step as an RVALUE index — the assignment's RIGHT side, which
    // the scan also never descended into. A frozen `a` here is an infinite
    // loop rather than a wrong answer.
    u32 i = (u32)0;
    while (i < (u32)4) { gSrc[i] = (i32)(i + (u32)1); i++; }
    u32 a = (u32)0; i32 sum = (i32)0;
    while (a < (u32)4) { sum = sum + gSrc[a++]; }
    Stdio.printf("sum=%d a=%d\n", sum, a);

    // PREFIX, as an index: the new value is the one that subscripts.
    u32 b = (u32)0; u32 k = (u32)0;
    while (k < (u32)4) { gPre[++b] = (i32)(k + (u32)10); k++; }
    Stdio.printf("pre=%d,%d,%d,%d b=%d\n", gPre[1], gPre[2], gPre[3], gPre[4], b);
}
