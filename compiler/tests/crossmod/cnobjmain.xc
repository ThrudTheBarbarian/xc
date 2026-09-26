// cnobjmain.xc — the program half of classnames.sh for a `-c` object. Built
// with -c itself and linked with cnobj.o; it imports cnobj's interface and
// names classes from it, and its own, at run time.
#import "Stdio.xc"
#import <cnobj>

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
    name("obj marker", (Object*)makeMarker());
    make("Local");
    make("Token");
    make("Marker");
    make("Nothing");
    Token* t = (Token* ?)Object.newInstanceOfClass(String.withCString("Marker"));
    Stdio.printf("marker tag=%d\n", t.tag);
    return 0;
    }
