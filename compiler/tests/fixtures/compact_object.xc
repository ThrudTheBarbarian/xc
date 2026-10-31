// compact_object — class instances with the 8-byte header (2026-10-31).
//
// On a compact-objects target `new C` takes an 8-byte header (magic and
// refcount) from _xtc_alloc_object; the dealloc comes from the vtable's
// fourth header word, and a weak reference's list head lives in a side table
// (private:docs/Design/compact-object-header.md). Each case must behave as
// with the 40-byte header:
//
//   T1  an instance's dealloc runs once, when its last reference goes
//   T2  a subclass's dealloc chains to its parent's
//   T3  a weak reference is zeroed when its object dies, and a second weak
//       slot pointing at the same object is zeroed too
//   T4  a weak slot re-pointed before the object dies is left alone by it
//   T5  many weakly referenced objects (the side table grows and reuses)
//   T6  an array of class (`new C[n]`, the full header) deallocs each element
//   T7  a class with no dealloc frees cleanly (a null dealloc word)

#import "Stdio.xc"

u32 gFreed;
u32 gBaseFreed;

class Plain { u32 v; void init(u32 x) { v = x; } }

class Base
{
    u32 tag;
    void init(u32 t) { tag = t; }
    void dealloc(void) { gBaseFreed = gBaseFreed + (u32)1; }
}

class Kid : Base
{
    u32 extra;
    void dealloc(void) { gFreed = gFreed + (u32)1; }
}

class Counted
{
    u32 id;
    void init(u32 i) { id = i; }
    void dealloc(void) { gFreed = gFreed + (u32)1; }
}

class Holder
{
    weak:Counted* a;
    weak:Counted* b;
}

void t1(void)
    {
    Counted* c = new Counted((u32)7);
    Counted* d = c;
    d = (Counted*)0;
    Stdio.printf("T1 alive %u freed %u\n", c.id, gFreed);
    }

void t2(void)
    {
    Kid* k = new Kid((u32)3);
    k.extra = (u32)4;
    Stdio.printf("T2 kid %u %u\n", k.tag, k.extra);
    }

void t3(Holder* h)
    {
    Counted* c = new Counted((u32)11);
    h.a = c;
    h.b = c;
    Stdio.printf("T3 before %u %u\n", h.a.id, h.b.id);
    }

void t4(Holder* h)
    {
    Counted* c = new Counted((u32)21);
    Counted* keep = new Counted((u32)22);
    h.a = c;
    h.a = keep;
    c = (Counted*)0;
    Stdio.printf("T4 still %u\n", h.a.id);
    }

i32 main(i32 argc, u8** argv)
    {
    t1();
    Stdio.printf("T1 after freed %u\n", gFreed);
    gFreed = (u32)0;
    t2();
    Stdio.printf("T2 after kid %u base %u\n", gFreed, gBaseFreed);
    gFreed = (u32)0;
    Holder* h = new Holder();
    t3(h);
    Stdio.printf("T3 after %u %u freed %u\n", (u32)(h.a == (Counted*)0), (u32)(h.b == (Counted*)0), gFreed);
    gFreed = (u32)0;
    t4(h);
    Stdio.printf("T4 after a-null %u freed %u\n", (u32)(h.a == (Counted*)0), gFreed);
    gFreed = (u32)0;
    u32 zeroed = (u32)0;
    for (u32 i = (u32)0; i < (u32)5000; i++)
        {
        Holder* g = new Holder();
        Counted* c = new Counted(i);
        g.a = c;
        c = (Counted*)0;
        if (g.a == (Counted*)0)
            zeroed = zeroed + (u32)1;
        }
    Stdio.printf("T5 zeroed %u freed %u\n", zeroed, gFreed);
    gFreed = (u32)0;
    Counted* arr = new Counted[4];
    arr = (Counted*)0;
    Stdio.printf("T6 freed %u\n", gFreed);
    Plain* p = new Plain((u32)5);
    u32 pv = p.v;
    p = (Plain*)0;
    Stdio.printf("T7 plain %u\n", pv);
    return 0;
    }
