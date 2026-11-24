// giorder.xc — links gioa.o and giob.o (-c, #649). Each object's global
// instance is set up before main, in link order, and then the program's own:
// gLog reads 129 when gioa.o comes first, 219 when giob.o does. A virtual call
// on gioa's instance reaches the override its vtable names.
#import "Stdio.xc"

i32 gLog = 0;

class Shape : Object
    {
    i32 id;
    i32 area(void) { return 0; }
    }

Shape* squareShape(void);
i32 areaOf(Shape* s);
i32 circleRadius(void);

class Mark : Object
    {
    i32 v;
    void init(void) { v = 9; gLog = gLog * 10 + 9; }
    }

Mark gMark;

i32 main(void)
    {
    Stdio.printf("order %d\n", gLog);
    Stdio.printf("area %d radius %d mark %d\n", areaOf(squareShape()), circleRadius(), gMark.v);
    return 0;
    }
