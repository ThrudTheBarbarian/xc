// Shapes whose characters also read the old way. `m +% p` is a percentage
// increase where Money defines `+%`; on integers `x +%101` is still `x + 5`,
// the binary literal `%101`. `a-->b` is Money's `-->` and `i-->0` is still
// `i--` then `>`. Each reading is chosen by the operands' types.
#import <Stdio.xc>

class Money
    {
    i32 c;
    static Money* of(i32 x) { Money* m = new Money(); m.c = x; return m; }
    Money* addPct(i32 p) :operator(self +% p) { return Money.of(c + c * p / 100); }
    bool before(Money* o) :operator(self --> o) { return c < o.c; }
    }

i32 main(void)
    {
    Money* m = Money.of(200);
    Money* n = m +% 50;
    i32 x = 7;
    i32 y = x +%101;
    Stdio.printf("pct %d old %d\n", n.c, y);
    i32 i = 3;
    i32 count = 0;
    while (i-->0)
        count++;
    Stdio.printf("goes %d old %d %d\n", m-->n ? 1 : 0, count, i);
    return 0;
    }
