// classes.xc — declaring a class, allocating one, and letting ARC free it.
#import "Foundation.xc"
#import "Stdio.xc"

class Point : Object
{
    // Instance variables. One `static` copy per CLASS is also allowed.
    i16 _x, _y;
    static u16 _made;          // how many Points have ever been built

    // init() runs on `new`. A subclass's init chains to its parent
    // automatically — you do not call super.init() by hand.
    void init(void)
    {
        _x = (i16)0;
        _y = (i16)0;
        _made = _made + (u16)1;
    }

    // A static method is called on the class, not on an instance. This is
    // the usual way to write a convenience constructor.
    static Point* at(i16 x, i16 y)
    {
        Point* p = new Point();
        p._x = x;
        p._y = y;
        return p;
    }

    // Ordinary methods. `self` is implicit.
    i16 x(void) { return _x; }
    i16 y(void) { return _y; }

    void translate(i16 dx, i16 dy) { _x = _x + dx; _y = _y + dy; }

    // Overriding description() gives every printf("%@") a useful form.
    String* description(void)
    {
        String* s = String.withCString("(");
        s.append(String.withI32((i32)_x));
        s.appendCString(", ");
        s.append(String.withI32((i32)_y));
        s.appendCString(")");
        return s;
    }

    static u16 made(void) { return _made; }

    // dealloc runs when the last reference goes. Like init, it chains up
    // the hierarchy on its own.
    void dealloc(void) { Stdio.printf("  dealloc %@\n", self); }
}

i32 main(void)
{
    // `new` allocates on the heap; ARC releases it when the last reference
    // goes out of scope. There is no free() to forget.
    Point* a = Point.at((i16)3, (i16)4);
    Stdio.printf("a        = %@\n", a);

    a.translate((i16)-1, (i16)2);
    Stdio.printf("moved    = %@  x=%d y=%d\n", a, a.x(), a.y());

    // Static state is shared by every instance.
    Point* b = Point.at((i16)10, (i16)20);
    Stdio.printf("b        = %@\n", b);
    Stdio.printf("made     = %d\n", Point.made());

    // Both are released here, at the end of the enclosing scope — watch the
    // dealloc lines appear after this one.
    Stdio.print("end of main\n");
    return 0;
}
