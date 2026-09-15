// int64_arith.xc — i64/u64 with literals WIDER THAN 32 BITS.
//
// The distinguishing feature is `1000000000000` written out in full. That kept
// this fixture out of tests/ and out of every differential for as long as the
// self-hosted lexer carried a literal in a u32: it would have truncated, and
// the diff would have been about the port's payload rather than about i64.
// Both are 64-bit now, so this is compared everywhere like anything else.
#import "Stdio.xc"

// Print a u64 as two 32-bit halves — printf's widest specifier is %ld (32-bit),
// so a 64-bit value cannot be shown in one piece yet.
void show(string tag, u64 v)
{
    Stdio.printf("%s hi=%ld lo=%ld\n", tag, (u32)(v >> (u64)32), (u32)v);
}

i32 main(void)
{
    show("2^40   ", (u64)1 << (u64)40);
    show("10^12  ", (u64)1000000 * (u64)1000000);
    show("sub    ", (u64)1000000000000 - (u64)1);
    show("div    ", (u64)1000000000000 / (u64)1000000);
    show("mod    ", (u64)1000000000007 % (u64)1000000);
    show("and    ", (u64)$FFFFFFFFFF & (u64)$FF00FF00FF);

    i64 n = (i64)0 - (i64)1000000000000;
    Stdio.printf("neg/1000000=%ld\n", (i32)(n / (i64)1000000));
    Stdio.printf("cmp=%d %d\n", (i16)((i64)5 > (i64)3), (i16)(n < (i64)0));
    return 0;
}
