// cnclient.xc — the program half of classnames.sh for a library. It imports
// libCnLib (built with --emit-lib) and names classes from it, and its own, at
// run time.
#import "Stdio.xc"
#import <CnLib>

class Local
    {
    i32 v;
    void init(void)
        {
        v = (i32)7;
        }
    }

void name(u8* what, Object* o)
    {
    if (o == (Object*)0)
        {
        Stdio.printf("%s: null\n", what);
        return;
        }
    String* n = o.className();
    Stdio.printf("%s: %s\n", what, n == (String*)0 ? "(no name)" : n.cString());
    }

void make(u8* cls)
    {
    Object* o = Object.newInstanceOfClass(String.withCString(cls));
    name(cls, o);
    }

i32 main(void)
    {
    name("lib wedge", (Object*)CnLib.makeWedge());
    make("Local");
    make("Shape");
    make("Square");
    make("Wedge");
    make("String");
    make("Nothing");
    Shape* s = (Shape* ?)Object.newInstanceOfClass(String.withCString("Square"));
    Stdio.printf("square sides=%d\n", s.count());
    Object* w = CnLib.make(String.withCString("Wedge"));
    name("lib lookup", w);
    Object* l = CnLib.make(String.withCString("Local"));
    name("lib lookup of a client class", l);
    return 0;
    }
