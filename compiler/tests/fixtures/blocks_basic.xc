// blocks_basic.xc — blocks v1 (task #26, private:docs/Design/blocks.md).
// Declaration with body, calls through the variable, snapshot captures,
// a block as a function parameter, re-assignment, the bare-body
// assignment sugar (signature inherited from the declaration), and auto.
#import "Stdio.xc"
#import "Foundation.xc"

u32 fn(block blk u32(u16 x, u16 y))
{
    return blk(3, 4) * blk(4, 5);
}

i32 main(void)
{
    block b u32(u16 x, u16 y) = { return (u32)x + (u32)y; }
    Stdio.printf("T1 %ld\n", b(2, 3));

    u32 base = (u32)100;
    block c u32(u16 n) = { return base + (u32)n; }
    base = (u32)999;                        // snapshot: c still sees 100
    Stdio.printf("T2 %ld\n", c(7));

    Stdio.printf("T3 %ld\n", fn(b));

    block d u32(u16 x, u16 y);
    d = b;
    Stdio.printf("T4 %ld\n", d(10, 20));

    d = { return (u32)x * (u32)y; };
    Stdio.printf("T5 %ld\n", d(6, 7));

    auto e = d;
    Stdio.printf("T6 %ld\n", e(2, 8));
    return 0;
}
