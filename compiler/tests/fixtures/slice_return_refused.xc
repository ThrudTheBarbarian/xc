//xtc-flags: expect=sema-error
// A subclass instance returned by value from a function that returns its
// superclass would be sliced: the copy keeps Square's class but has only
// Shape's ivars, so area() would run Square's method on it (#552).
// Refused: returning a 'Square' by value as a 'Shape' would slice it; return a 'Square', or a reference ('Shape*')
#import <Stdio.xc>

class Shape : Object { i32 w; i32 area(void) { return w; } }
class Square : Shape { i32 extra; i32 area(void) { return w * w; } }

Shape make(void)
    {
    Square s;
    s.w = 3;
    s.extra = 9;
    return s;
    }

i32 main(void)
    {
    Shape x = make();
    Stdio.printf("%d\n", x.area());
    return 0;
    }
