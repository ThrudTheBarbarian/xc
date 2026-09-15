#import "Stdio.xc"
#import <Adder>
i32 main(void)
    {
    Adder* a = new Adder();
    Stdio.printf("add=%ld\n", a.add((i32)2));
    Stdio.printf("twice=%ld\n", twice((i32)21));
    return 0;
    }
