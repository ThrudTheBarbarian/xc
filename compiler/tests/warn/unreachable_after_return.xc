//xtc-warn: unreachable
// Code after an unconditional return in the same block. The IR has the
// statement in a block nothing branches to, so this is the cheapest possible
// reachability question — and the one that proves the plumbing works.
#import "Stdio.xc"
i32 pick(i32 n)
    {
    return n + (i32)1;
    Stdio.printf("never\n"); // unreachable
    return (i32)0;
    }
i32 main(void)
    {
    return pick((i32)1) == (i32)2 ? (i32)0 : (i32)1;
    }
