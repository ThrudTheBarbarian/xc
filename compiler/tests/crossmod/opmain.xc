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
    return 0;
    }
