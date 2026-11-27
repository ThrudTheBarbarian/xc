// `S c = a;` of a struct holding a class reference retains it, as `c = a`
// does: c's scope exit releases it, so without the retain the object was
// freed while `a` still held it, then freed again (#757). A copy from a
// member does the same.
#import "Stdio.xc"

class Box
    {
    i32 v;
    void dealloc(void) { Stdio.printf("dealloc %d\n", v); }
    }

typedef struct { Box* b; u64 off; } Hdr;

struct Holder { Hdr h; u32 n; }

Hdr make(i32 v)
    {
    Hdr h;
    h.b = new Box();
    h.b.v = v;
    return h;
    }

i32 main(void)
    {
    Hdr a = make(1);
        {
        Hdr c = a;
        Stdio.printf("copy %d\n", c.b.v);
        }
    Stdio.printf("after scope %d\n", a.b.v);
    Holder hd;
    hd.h = make(3);
        {
        Hdr d = hd.h;
        Stdio.printf("member copy %d\n", d.b.v);
        }
    Stdio.printf("after member scope %d\n", hd.h.b.v);
    a = make(2);
    Stdio.printf("end\n");
    return 0;
    }
