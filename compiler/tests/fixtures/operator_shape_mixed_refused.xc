//xtc-flags: expect=sema-error
// The readings of one expression are chosen together: `**` cannot be Num's
// operator in one place and `* *` in another of the same expression.
// Refused: '**' is the operator of 'Num' in one place in this expression and has its built-in meaning in another; use parentheses
#import <Stdio.xc>

class Num
    {
    i32 v;
    Num* pow(Num* e) :operator(self ** e) { return e; }
    i32 value(i32 k) :operator(self + k) { return v + k; }
    }

i32 main(void)
    {
    Num* a = new Num();
    i32 x = 2;
    i32* p = &x;
    i32 r = a ** a + x ** p;
    return r;
    }
