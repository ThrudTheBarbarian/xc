// Widening match: calling a u16 overload with a u8 arg.

#import <Stdio.xc>

void f(u16 v)
    {
    Stdio.printf("u16:%d\n", v);
    }

void main(void)
    {
    u8 x = 42;
    f(x);
    return;
    }
