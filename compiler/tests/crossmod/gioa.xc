// gioa.xc — an object built with -c for giorder.xc (#649): a global instance
// with an init and a vtable. Its load-time constructor sets it up before the
// program's main, and logs that it ran in the program's gLog.
extern i32 gLog;

class Shape : Object
    {
    i32 id;
    i32 area(void) { return 0; }
    }

class Square : Shape
    {
    i32 side;
    void init(void) { side = 7; id = 1; gLog = gLog * 10 + 1; }
    i32 area(void) { return side * side; }
    }

Square gSquare;

Shape* squareShape(void) { return &gSquare; }
i32 areaOf(Shape* s) { return s.area(); }
