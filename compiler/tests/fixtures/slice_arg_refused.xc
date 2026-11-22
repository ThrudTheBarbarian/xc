//xtc-flags: expect=sema-error
// A subclass instance passed by value into a superclass parameter would be
// sliced (#552), for a free function and for a method alike.
// Refused: argument 1 of 'take': passing a 'Square' by value as a 'Shape' would slice it; take a 'Square', or a reference ('Shape*')
// Refused: argument 1 of 'Box.put': passing a 'Square' by value as a 'Shape' would slice it; take a 'Square', or a reference ('Shape*')
#import <Stdio.xc>

class Shape : Object { i32 w; i32 area(void) { return w; } }
class Square : Shape { i32 extra; i32 area(void) { return w * w; } }

class Box : Object
    {
    i32 seen;
    void put(Shape v) { seen = v.area(); }
    }

i32 take(Shape v) { return v.area(); }

i32 main(void)
    {
    Square q;
    q.w = 5;
    Box* b = new Box();
    b.put(q);
    Stdio.printf("%d %d\n", take(q), b.seen);
    return 0;
    }
