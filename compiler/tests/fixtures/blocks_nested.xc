// blocks_nested.xc — blocks v1: a literal inside a literal (the inner
// capture of an enclosing local composes THROUGH the outer impl's ivar),
// and a block parameter shadowing an enclosing local (the #23 family).
#import "Stdio.xc"
#import "Foundation.xc"
i32 main(void)
{
    u32 k = (u32)1000;
    // nested literals: inner captures k THROUGH the outer impl's ivar
    block outer u32(u32 n) = {
        block inner u32(u32 m) = { return k + m; }
        return inner(n) + (u32)1;
    }
    Stdio.printf("T1 %ld\n", outer((u32)5));
    // shadowing: block param shadows an outer local (task #23 family)
    u32 x = (u32)77;
    block s u32(u32 x) = { return x * (u32)2; }
    Stdio.printf("T2 %ld %ld\n", s((u32)21), x);
    return 0;
}
