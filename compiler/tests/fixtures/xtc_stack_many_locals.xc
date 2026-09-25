//xtc-flags: --xtc-stack
// xtc_stack_many_locals.xc — functions with many locals under --xtc-stack on
// xt6502. The locals that do not fit zero page sit on the hardware stack after
// the return address has moved to the software stack, and address-taken
// locals take software-stack frame slots behind the saved registers. Values
// live across calls check that neither frame is disturbed by a callee's.
#import "Stdio.xc"

i32 poke(i32 v)
{
    return v ^ 5;
}

i32 wide(i32 a, i32 b, i32 c)
{
    i32 l0 = a + 1;
    i32 l1 = b + 2;
    i32 l2 = c + 3;
    i32 l3 = l0 * 2;
    i32 l4 = l1 * 3;
    i32 l5 = l2 * 4;
    i32 l6 = poke(l3);
    i32 l7 = poke(l4);
    i32 l8 = poke(l5);
    i32 l9 = l0 + l1 + l2;
    i32 l10 = l3 - l4 + l5;
    i32 l11 = l6 + l7 + l8;
    i32 l12 = poke(l9 + l10);
    i32 l13 = poke(l11 - l12);
    return l0 + l1 + l2 + l3 + l4 + l5 + l6 + l7 + l8 + l9 + l10 + l11 + l12 + l13;
}

// Two arrays whose addresses are taken, in a function that calls: both live in
// this call's software-stack frame, after its 8-byte header.
i32 buffers(i32 seed)
{
    u8 small[8];
    i32 big[6];
    for (i32 i = 0; i < 8; i++)
        small[i] = (u8)(seed + i);
    for (i32 i = 0; i < 6; i++)
        big[i] = poke(seed * i);
    i32 total = 0;
    for (i32 i = 0; i < 8; i++)
        total = total + (i32)small[i];
    for (i32 i = 0; i < 6; i++)
        total = total + big[i];
    return total;
}

i32 nest(i32 depth)
{
    if (depth == 0)
        return buffers(1);
    i32 here = buffers(depth);
    i32 below = nest(depth - 1);
    return here + below;
}

struct Pair
{
    i32 x;
    i32 y;
}

Pair swapped(Pair p)
{
    Pair q;
    q.x = poke(p.y);
    q.y = poke(p.x);
    return q;
}

i32 main(void)
{
    Stdio.printf("wide = %d\n", wide(3, 4, 5));
    Stdio.printf("buffers = %d\n", buffers(10));
    Stdio.printf("nest = %d\n", nest(4));
    Pair p;
    p.x = 11;
    p.y = 22;
    Pair q = swapped(p);
    Stdio.printf("swapped = %d %d\n", q.x, q.y);
    return 0;
}
