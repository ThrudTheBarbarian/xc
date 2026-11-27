// `new` on a typedef of a class builds the class: its init runs and its
// methods dispatch, and the alias's pointer is the class's (#730). Under
// the alias it was allocated as raw memory, with no vtable and no init.
// A typedef of a typedef too.
#import "Stdio.xc"

class Foo
    {
    i32 v;
    void init(void) { v = 7; }
    i32 get(void) { return v; }
    }

typedef Foo Bar;
typedef Bar Baz;

i32 main(void)
    {
    Bar* b = new Bar();
    Foo* f = b;
    Baz* z = new Baz();
    z.v = z.v + 1;
    Stdio.printf("%d %d %d\n", b.get(), f.v, z.get());
    return 0;
    }
