//xtc-flags: expect=sema-error
// A superclass value initialised from a subclass instance would be sliced
// (#552).
// Refused: initialising a 'Shape' by value from a 'Square' would slice it; declare a 'Square', or a reference ('Shape*')
#import <Stdio.xc>

class Shape : Object { i32 w; i32 area(void) { return w; } }
class Square : Shape { i32 extra; i32 area(void) { return w * w; } }

i32 main(void)
    {
    Square q;
    q.w = 5;
    Shape y = q;
    Stdio.printf("%d\n", y.area());
    return 0;
    }
