// Copies and returns of a stack instance by value are allowed when the class
// is the same, and a reference to a subclass instance (a pointer) is not a
// copy: none of these is the slicing refused by #552.
#import <Stdio.xc>

class Shape : Object { i32 w; i32 area(void) { return w; } }
class Square : Shape { i32 extra; i32 area(void) { return w * w + extra; } }

Square makeSquare(i32 w)
    {
    Square s;
    s.w = w;
    s.extra = 1;
    return s;
    }

Shape makeShape(i32 w)
    {
    Shape s;
    s.w = w;
    return s;
    }

i32 squareArea(Square v) { return v.area(); }

void copies(void)
    {
    Square a = makeSquare(3);
    Square b = a;
    b.w = 4;
    Square c;
    c = b;
    Stdio.printf("%d %d %d %d\n", a.area(), b.area(), c.area(), squareArea(c));

    Shape s = makeShape(7);
    Shape t = s;
    Stdio.printf("%d %d\n", s.area(), t.area());
    }

void references(void)
    {
    Square a;
    a.w = 3;
    a.extra = 1;
    weak:Shape* p = &a;
    Shape* h = new Square();
    h.w = 2;
    Stdio.printf("%d %d\n", p.area(), h.area());
    }

i32 main(void)
    {
    copies();
    references();
    return 0;
    }
