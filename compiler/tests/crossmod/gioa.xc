// gioa.xc — an object built with -c for giorder.xc (#649): a global instance
// with an init and a vtable. Its load-time constructor sets it up before the
// program's main, and its init says so.
#import "Stdio.xc"

class Shape : Object
    {
    i32 id;
    i32 area(void) { return 0; }
    }

class Square : Shape
    {
    i32 side;
    void init(void) { side = 7; id = 1; Stdio.printf("square set up\n"); }
    i32 area(void) { return side * side; }
    }

Square gSquare;

Shape* squareShape(void) { return &gSquare; }
i32 areaOf(Shape* s) { return s.area(); }
