// for_ever_left_by_return.xc — bug 602 (UXKit 043). A `for (;;)` whose only
// way out is `return`, inside an `if` with code after it. The loop's exit
// block is unreachable by construction, and the reference compiler's IR
// verifier rejected the module ("block 'bb_3_for_exit' ... is unreachable from
// entry") although the code is legal and the shipped compiler built it. Code
// written after such a loop is dead, and that is the program's business.
#import "Stdio.xc"

i32 firstOver(i32* v, i32 n, i32 limit)
{
    if (n > (i32)0)
    {
        i32 i = (i32)0;
        for (;;)
        {
            if (v[i] > limit)
                return v[i];
            i = i + (i32)1;
            if (i == n)
                return (i32)-1;
        }
    }
    return (i32)0;
}

i32 deadAfterLoop(i32 k)
{
    for (;;)
    {
        if (k > (i32)3)
            return k;
        k = k + (i32)1;
    }
    if (k == (i32)99)        // dead: after a loop nothing leaves by `break`
        Stdio.printf("never\n");
    return (i32)-7;
}

i32 main(void)
{
    i32 v[5];
    v[0] = (i32)1; v[1] = (i32)4; v[2] = (i32)9; v[3] = (i32)2; v[4] = (i32)7;
    Stdio.printf("%d %d %d\n", firstOver(&v[0], (i32)5, (i32)5), firstOver(&v[0], (i32)5, (i32)50), firstOver(&v[0], (i32)0, (i32)5));
    Stdio.printf("%d\n", deadAfterLoop((i32)0));
    return 0;
}
