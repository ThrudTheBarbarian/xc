//xtc-flags: expect=sema-error
// A subclass instance assigned by value to a superclass value would be sliced
// (#552).
// Refused: assigning a 'Square' by value to a 'Shape' would slice it; assign it to a 'Square', or a reference ('Shape*')
#import <Stdio.xc>

class Shape : Object { i32 w; i32 area(void) { return w; } }
class Square : Shape { i32 extra; i32 area(void) { return w * w; } }

i32 main(void)
    {
    Square q;
    q.w = 5;
    Shape y;
    y.w = 2;
    y = q;
    Stdio.printf("%d\n", y.area());
    return 0;
    }
