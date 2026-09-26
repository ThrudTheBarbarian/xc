//xtc-na: xt6502 — Object has no className / newInstanceOfClass there (class_names_xt6502.xc pins the error)
// class_names.xc — runtime class names: `o.className()` is the receiver's
// DYNAMIC class name, and `Object.newInstanceOfClass(name)` makes an instance
// as `new C()` would: refcount 1 owned by the caller, zero-argument init run,
// the parents' inits chained; a class with only parameterised inits comes back
// zero-filled with no init run; an unknown name gives null.
#import "Stdio.xc"

u16 gLive;

class Point
    {
    i32 x;
    i32 y;
    void init(void)
        {
        x = (i32)3;
        y = (i32)4;
        gLive = gLive + (u16)1;
        }
    void dealloc(void)
        {
        gLive = gLive - (u16)1;
        }
    }

class Point3D : Point
    {
    i32 z;
    void init(void)
        {
        z = (i32)5;
        }
    }

class OnlyArgs
    {
    i32 v;
    void init(i32 a)
        {
        v = a;
        Stdio.printf("OnlyArgs.init ran\n");
        }
    }

class Plain
    {
    i32 w;
    }

void show(u8* what, Object* o)
    {
    if (o == (Object*)0)
        {
        Stdio.printf("%s: null\n", what);
        return;
        }
    String* n = o.className();
    Stdio.printf("%s: %s\n", what, n == (String*)0 ? "(none)" : n.cString());
    }

void makeSome(void)
    {
    for (i32 i = (i32)0; i < (i32)3; i = i + (i32)1)
        {
        Object* q = Object.newInstanceOfClass(String.withCString("Point3D"));
        Point3D* r = (Point3D* ?)q;
        Stdio.printf("made %s x=%d y=%d z=%d\n", q.className().cString(), r.x, r.y, r.z);
        }
    }

i32 main(void)
    {
    Point* p = new Point3D();
    show("static Point, dynamic Point3D", (Object*)p);
    show("Point", (Object*)new Point());
    show("a String", (Object*)String.withCString("text"));
    show("Plain", (Object*)new Plain());

    makeSome();
    Stdio.printf("live after the loop: %u\n", gLive);

    Object* a = Object.newInstanceOfClass(String.withCString("OnlyArgs"));
    show("OnlyArgs", a);
    Stdio.printf("OnlyArgs.v=%d\n", ((OnlyArgs*)a).v);

    show("Nope", Object.newInstanceOfClass(String.withCString("Nope")));
    show("empty name", Object.newInstanceOfClass(String.withCString("")));
    show("null name", Object.newInstanceOfClass((String*)0));
    show("prefix of a name", Object.newInstanceOfClass(String.withCString("Poin")));

    Object* s = Object.newInstanceOfClass(String.withCString("String"));
    show("String by name", s);
    Object* o = Object.newInstanceOfClass(String.withCString("Object"));
    show("Object by name", o);
    return 0;
    }
