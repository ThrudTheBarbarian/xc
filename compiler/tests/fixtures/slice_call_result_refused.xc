//xtc-flags: expect=sema-error
// A call's by-value result whose type is a subclass, stored into a superclass
// value, would be sliced (#552).
// Refused: initialising a 'Shape' by value from a 'Square' would slice it; declare a 'Square', or a reference ('Shape*')
// Refused: assigning a 'Square' by value to a 'Shape' would slice it; assign it to a 'Square', or a reference ('Shape*')
#import <Stdio.xc>

class Shape : Object { i32 w; i32 area(void) { return w; } }
class Square : Shape { i32 extra; i32 area(void) { return w * w; } }

Square makeSquare(i32 w)
    {
    Square s;
    s.w = w;
    return s;
    }

i32 main(void)
    {
    Shape z = makeSquare(4);
    Stdio.printf("%d\n", z.area());
    z = makeSquare(6);
    Stdio.printf("%d\n", z.area());
    return 0;
    }
