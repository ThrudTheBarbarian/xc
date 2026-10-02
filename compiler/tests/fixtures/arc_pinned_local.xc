// arc_pinned_local.xc — an address-taken class-pointer local owns its slot.
//
// `Tok* t = 0; Make.into(&t);` lets the callee store into `t` through a
// pointer. That store already retains (arc_out_parameter.xc, bug 034); the
// LOCAL used to do nothing. It neither released the slot's old value on
// assignment nor released what it held at scope exit, so every value that
// came back through an out-parameter leaked. Worse, a PARAMETER whose
// address was taken held the caller's borrowed argument unretained, so the
// callee's release-the-old-value freed an object the function never owned.
//
// Each test counts deallocations, which a leak or a double release changes.
//   T1  out-parameter in a loop: every value is released.
//   T2  a callee that never writes: the null slot is released safely.
//   T3  `return t` after an out-call: the value outlives the callee.
//   T4  break and continue out of a scope holding one: released once each.
//   T5  `t = t` on a pinned local.
//   T6  a pinned PARAMETER: the caller's argument survives the callee's write.
//   T7  an owned initialiser that an out-call then replaces.
//   T8  an inner local of another type shadowing a pinned one.

#import "Stdio.xc"

u16 deallocCount;

class Tok
{
    u16 id;
    void dealloc(void)
    {
        deallocCount = deallocCount + 1;
    }
}

class Make
{
    static void into(Tok** out, u16 id)
    {
        Tok* t = new Tok();
        t.id = id;
        *out = t;
    }

    static void nothing(Tok** out)
    {
    }

    static Tok* viaOut(u16 id)
    {
        Tok* t = (Tok*)0;
        Make.into(&t, id);
        return t;
    }

    static u16 replaceArg(Tok* p)
    {
        Make.into(&p, (u16)99);
        return p.id;
    }
}

void t1(void)
{
    deallocCount = 0;
    for (u16 i = 0; i < 10; i = i + 1)
    {
        Tok* t = (Tok*)0;
        Make.into(&t, i);
    }
    Stdio.printf("T1 deallocs=%d\n", (i16)deallocCount);
}

void t2(void)
{
    deallocCount = 0;
    {
        Tok* t = (Tok*)0;
        Make.nothing(&t);
    }
    Stdio.printf("T2 deallocs=%d\n", (i16)deallocCount);
}

void t3(void)
{
    deallocCount = 0;
    {
        Tok* k = Make.viaOut((u16)7);
        Stdio.printf("T3 id=%d alive deallocs=%d\n", (i16)k.id, (i16)deallocCount);
    }
    Stdio.printf("T3 after deallocs=%d\n", (i16)deallocCount);
}

void t4(void)
{
    deallocCount = 0;
    for (u16 i = 0; i < 6; i = i + 1)
    {
        Tok* t = (Tok*)0;
        Make.into(&t, i);
        if (i == 1)
            continue;
        if (i == 4)
            break;
    }
    Stdio.printf("T4 deallocs=%d\n", (i16)deallocCount);
}

void t5(void)
{
    deallocCount = 0;
    {
        Tok* t = (Tok*)0;
        Make.into(&t, (u16)5);
        t = t;
        Stdio.printf("T5 id=%d deallocs=%d\n", (i16)t.id, (i16)deallocCount);
    }
    Stdio.printf("T5 after deallocs=%d\n", (i16)deallocCount);
}

void t6(void)
{
    deallocCount = 0;
    {
        Tok* mine = new Tok();
        mine.id = 1;
        u16 got = Make.replaceArg(mine);
        Stdio.printf("T6 got=%d mine=%d deallocs=%d\n", (i16)got, (i16)mine.id, (i16)deallocCount);
    }
    Stdio.printf("T6 after deallocs=%d\n", (i16)deallocCount);
}

void t7(void)
{
    deallocCount = 0;
    {
        Tok* s = new Tok();
        s.id = 1;
        Make.into(&s, (u16)2);
        Stdio.printf("T7 id=%d deallocs=%d\n", (i16)s.id, (i16)deallocCount);
    }
    Stdio.printf("T7 after deallocs=%d\n", (i16)deallocCount);
}

void t8(void)
{
    deallocCount = 0;
    {
        Tok* t = (Tok*)0;
        Make.into(&t, (u16)8);
        {
            u16 t = 3;
            t = t + 1;
            Stdio.printf("T8 inner=%d\n", (i16)t);
        }
        Stdio.printf("T8 id=%d deallocs=%d\n", (i16)t.id, (i16)deallocCount);
    }
    Stdio.printf("T8 after deallocs=%d\n", (i16)deallocCount);
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
    t8();
    return 0;
}
