// A class instance held by value in a struct is the instance inline and
// behaves as a stack instance (#756): set up with the struct (fields zero,
// vtable seeded, init run), its references retained when the struct is
// copied, and its dealloc run when the struct goes. A struct inside a
// struct, an array of such structs, a method call through the field and an
// assignment to it. A field written `Box* b` stays a reference.
#import "Stdio.xc"

class Box
    {
    i32 v;
    void dealloc(void) { Stdio.printf("box %d freed\n", v); }
    }

class V
    {
    Box* b;
    i32 n;
    void init(void) { n = 1; }
    i32 twice(void) { return n * 2; }
    }

struct S { i32 k; V v; }
struct Outer { S s; u8 tag; }

i32 main(void)
    {
        {
        S s;
        Stdio.printf("init n %d, b %d, twice %d\n", s.v.n, s.v.b == (Box*)0 ? 0 : 1, s.v.twice());
        s.v.b = new Box();
        s.v.b.v = 5;
        s.v.n = 9;
        S c = s;
        c.v.n = 4;
        Stdio.printf("copy %d %d, orig %d, same box %d\n", c.v.n, c.v.b.v, s.v.n, c.v.b == s.v.b ? 1 : 0);
        }
    Stdio.printf("scope 1 done\n");
        {
        Outer o;
        o.s.v.b = new Box();
        o.s.v.b.v = 6;
        Outer p = o;
        Stdio.printf("nested %d %d\n", p.s.v.b.v, p.s.v.twice());
        }
    Stdio.printf("scope 2 done\n");
        {
        S arr[2];
        arr[0].v.b = new Box();
        arr[0].v.b.v = 7;
        arr[1].v.b = new Box();
        arr[1].v.b.v = 8;
        V w;
        w.b = new Box();
        w.b.v = 9;
        w.n = 3;
        arr[1].v = w;
        Stdio.printf("array %d %d %d\n", arr[0].v.b.v, arr[1].v.b.v, arr[1].v.n);
        }
    Stdio.printf("scope 3 done\n");
    return 0;
    }
