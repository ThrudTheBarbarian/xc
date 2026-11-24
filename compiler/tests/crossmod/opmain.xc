// opmain.xc — the program half of operators.sh. Built with -c and linked with
// opobj.o; it imports opobj's interface, so Money's operators reach it there.
#import "Stdio.xc"
#import <opobj>

i32 main(void)
    {
    Money* a = Money.of(150);
    Money* b = Money.of(25);
    Stdio.printf("sum %d\n", (a + b).cents);
    Stdio.printf("neg %d\n", (-a).cents);
    Stdio.printf("scaled %d\n", (3 * b).cents);
    a += b;
    Stdio.printf("compound %d\n", a.cents);
    Ledger* l = new Ledger();
    l[0, 1] = 5;
    l[1, 2] = 7;
    l[1, 2] += 3;
    Stdio.printf("index %d %d %d\n", l[0, 1], l[1, 2], l[1..6]);
    Pow* pa = Pow.of(2);
    Pow* pb = Pow.of(3);
    Pow* pc = Pow.of(2);
    i32 x = 5;
    i32* p = &x;
    Stdio.printf("shapes %d %d %d\n", (2 * pa ** pb ** pc).v, (pa ⊗ pb).v, x**p);
    return 0;
    }
