// global_instance.xc — a class instance declared by value at file scope
// (#641). It is the instance itself, in data behind a header with an
// immortal count, set up before main and never torn down.
//
//   T1  fields written and read (the #641 crash)
//   T2  its zero-argument init ran before main, in declaration order
//   T3  virtual dispatch through its vtable
//   T4  an object ivar is retained, and freed only when replaced
//   T5  copies in and out, with the members' references retained
//   T6  `&g` held strongly and weakly in locals, fields and a container: the
//       instance is never freed and a weak pointer to it is never cleared
//   T7  an instance held by value inside a global instance
//   T8  passed to a strong parameter and returned as a reference
//
// Shape's dealloc prints, so a teardown at exit would show after "end".
// Assigning to an instance takes its old value apart (T5), as for a stack
// instance; Holder counts those.

#import "Stdio.xc"
#import "Array.xc"

i32 gInits = 0;
i32 gDeallocs = 0;
i32 gBoxes = 0;
i32 gHolders = 0;

class Box : Object
    {
    i32 v;
    void init(void) { gBoxes = gBoxes + 1; }
    void dealloc(void) { gBoxes = gBoxes - 1; }
    }

class P : Object
    {
    i32 a;
    i32 b;
    }

class Shape : Object
    {
    i32 order;
    void init(void) { gInits = gInits + 1; order = gInits; }
    void dealloc(void) { gDeallocs = gDeallocs + 1; Stdio.printf("Shape dealloc %d\n", order); }
    i32 sides(void) { return 0; }
    }

class Square : Shape
    {
    i32 sides(void) { return 4; }
    }

class Holder : Object
    {
    Box* box;
    i32 n;
    void dealloc(void) { gHolders = gHolders + 1; }
    }

class Inner : Object
    {
    i32 x;
    void init(void) { x = 7; }
    i32 twice(void) { return x * 2; }
    }

class Outer : Object
    {
    Inner inner;
    i32 y;
    void init(void) { y = inner.x + 1; }
    }

class Keeper : Object
    {
    Shape* strongRef;
    weak:Shape* weakRef;
    }

P g;
Square first;
Shape second;
Holder h;
Outer o;
Keeper gk;
weak:Shape* gWeak;

i32 count(Shape* s) { return s.sides(); }
Shape* pass(Shape* s) { return s; }

i32 main(void)
    {
    g.a = 3;
    g.b = 4;
    Stdio.printf("T1 %d %d\n", g.a, g.b);

    Stdio.printf("T2 inits %d first %d second %d\n", gInits, first.order, second.order);

    Shape* s = &first;
    Stdio.printf("T3 %d %d %d\n", first.sides(), s.sides(), second.sides());

    h.box = new Box();
    h.box.v = 5;
    Stdio.printf("T4 box %d live %d\n", h.box.v, gBoxes);
    h.box = new Box();
    Stdio.printf("T4 replaced live %d\n", gBoxes);

    Holder c = h;
    c.n = 9;
    Stdio.printf("T5 copy %d n %d g.n %d live %d\n", c.box == h.box, c.n, h.n, gBoxes);
    c.box = new Box();
    h = c;
    Stdio.printf("T5 assign n %d same %d live %d old taken apart %d\n", h.n, h.box == c.box, gBoxes, gHolders);

        {
        Shape* a = &second;
        weak:Shape* w = &second;
        gk.strongRef = &first;
        gk.weakRef = &second;
        gWeak = &first;
        Array* arr = new Array();
        arr.add(&first);
        arr.add(&second);
        arr.removeAll();
        a = nil;
        Stdio.printf("T6 weak %d\n", w != nil);
        }
    gk.strongRef = nil;
    Stdio.printf("T6 deallocs %d weak %d %d sides %d\n", gDeallocs, gk.weakRef != nil, gWeak != nil, gWeak.sides());

    Stdio.printf("T7 x %d y %d twice %d\n", o.inner.x, o.y, o.inner.twice());

    Stdio.printf("T8 %d %d\n", count(&first), pass(&second).order);
    Stdio.printf("end deallocs %d\n", gDeallocs);
    return 0;
    }
