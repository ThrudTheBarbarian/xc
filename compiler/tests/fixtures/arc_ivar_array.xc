// arc_ivar_array.xc — an array ivar of class pointers owns its elements.
//
// `Part* parts[4];` in a class used to be a row of raw slots: `parts[i] = p`
// stored without retaining, so the Part died when the method that made it
// returned, and the slot dangled. On arm64 the next `new Part()` got the same
// block, so two "different" objects read back as one. A scalar object ivar,
// a local `T* a[N]` and a global array of class pointers all owned theirs.
//
// Each test counts Part deallocations, which a leak or a double release
// changes.
//   T1  UXKit's repro: two boxes keep their own parts.
//   T2  replacing an element releases the old one.
//   T3  freeing the box releases every element.
//   T4  `obj.parts[i] = p` from outside the class.
//   T5  a subclass storing into its parent's array ivar.
//   T6  `parts[i] = parts[i]` keeps the element.
//   T7  a class that owns ONLY the array, made and freed in a loop: its
//       elements must start null, or replacing one releases garbage.

#import "Stdio.xc"

u16 deallocCount;

class Part
{
    i32 v;
    void dealloc(void)
    {
        deallocCount = deallocCount + 1;
    }
}

class Box
{
    i32 tag;
    Part* parts[4];

    void put(i32 i, i32 v)
    {
        Part* p = new Part();
        p.v = v;
        parts[i] = p;
    }

    void keep(i32 i)
    {
        parts[i] = parts[i];
    }

    i32 at(i32 i)
    {
        return parts[i].v;
    }
}

class BigBox : Box
{
    void putTwice(i32 i, i32 v)
    {
        put(i, v);
        Part* q = new Part();
        q.v = v + 1;
        parts[i] = q;
    }
}

class OnlyArray
{
    Part* slots[3];
}

void t1(void)
{
    Box* x = new Box();
    x.put(0, 111);
    Box* y = new Box();
    y.put(0, 222);
    Stdio.printf("T1 x=%d y=%d same=%d\n", x.at(0), y.at(0), x.parts[0] == y.parts[0] ? 1 : 0);
}

void t2(void)
{
    deallocCount = 0;
    Box* b = new Box();
    b.put(1, 5);
    b.put(1, 6);
    Stdio.printf("T2 v=%d deallocs=%d\n", b.at(1), (i16)deallocCount);
}

void t3(void)
{
    deallocCount = 0;
    {
        Box* b = new Box();
        b.put(0, 1);
        b.put(2, 3);
        b.put(3, 4);
    }
    Stdio.printf("T3 deallocs=%d\n", (i16)deallocCount);
}

void t4(void)
{
    deallocCount = 0;
    {
        Box* b = new Box();
        Part* p = new Part();
        p.v = 44;
        b.parts[2] = p;
        p = (Part*)0;
        Stdio.printf("T4 v=%d deallocs=%d\n", b.at(2), (i16)deallocCount);
    }
    Stdio.printf("T4 after deallocs=%d\n", (i16)deallocCount);
}

void t5(void)
{
    deallocCount = 0;
    {
        BigBox* b = new BigBox();
        b.putTwice(1, 50);
        Stdio.printf("T5 v=%d deallocs=%d\n", b.at(1), (i16)deallocCount);
    }
    Stdio.printf("T5 after deallocs=%d\n", (i16)deallocCount);
}

void t6(void)
{
    deallocCount = 0;
    Box* b = new Box();
    b.put(3, 9);
    b.keep(3);
    Stdio.printf("T6 v=%d deallocs=%d\n", b.at(3), (i16)deallocCount);
}

void t7(void)
{
    deallocCount = 0;
    for (u16 i = 0; i < 20; i = i + 1)
    {
        OnlyArray* o = new OnlyArray();
        Part* p = new Part();
        p.v = (i32)i;
        o.slots[1] = p;
        Part* q = new Part();
        q.v = (i32)i + 100;
        o.slots[1] = q;
    }
    Stdio.printf("T7 deallocs=%d\n", (i16)deallocCount);
}

i32 main(void)
{
    t1();
    t2();
    t3();
    t4();
    t5();
    t6();
    t7();
    return 0;
}
