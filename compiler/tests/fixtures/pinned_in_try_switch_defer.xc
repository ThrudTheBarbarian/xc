//xtc-flags: target=arm64
// A local whose address is taken, or a struct or array local, declared inside
// a try, a catch, a switch case, a defer or a for-in over a collection, needs
// a frame slot like one in a loop. The pre-scans that
// give it one walked blocks, ifs and loops only: `&v` there was refused, and
// an array there was given no slot and faulted at its first use.
#import "Stdio.xc"
#import "Error.xc"
class E <Error> { String* message(void) { return String.withCString("e"); } }
void set7(u32* p) { *p = (u32)7; }
void maybe(u32 i) throws { if (i == (u32)9) throw new E(); }

void inTry(void) throws
    {
    try
        {
        maybe((u32)1);
        u32 v = (u32)1;
        set7(&v);
        u32 a[2];
        a[1] = (u32)2;
        set7(&a[0]);
        Stdio.printf("try %u %u %u\n", v, a[0], a[1]);
        }
    catch (E e) { Stdio.printf("not reached\n"); }
    }

void inCatch(void)
    {
    try { maybe((u32)9); }
    catch (E e)
        {
        u32 v = (u32)1;
        set7(&v);
        u32 a[1];
        set7(&a[0]);
        Stdio.printf("catch %u %u\n", v, a[0]);
        }
    }

void inSwitch(u32 k)
    {
    switch (k)
        {
        case 1:
            {
            u32 v = (u32)1;
            set7(&v);
            u32 a[1];
            set7(&a[0]);
            Stdio.printf("switch %u %u\n", v, a[0]);
            }
        default: { }
        }
    }

void inDefer(void)
    {
    defer
        {
        u32 v = (u32)1;
        set7(&v);
        u32 a[1];
        set7(&a[0]);
        Stdio.printf("defer %u %u\n", v, a[0]);
        }
    Stdio.printf("body\n");
    }

struct S { float mean; float median[4]; }
class L : Object { float level[3]; }
S make(void) { S s; s.median[0] = (float)7.0; return s; }

void inForIn(Array<L>* ls)
    {
    for (L* l in ls)
        {
        S st = make();
        l.level[2] = st.median[0];
        u32 v = (u32)1;
        set7(&v);
        Stdio.printf("forin %u\n", v);
        }
    }

i32 main(void)
    {
    try { inTry(); } catch (E e) { }
    inCatch();
    inSwitch((u32)1);
    inDefer();
    Array<L>* ls = new Array();
    ls.add(new L());
    inForIn(ls);
    Stdio.printf("level %.1f\n", (double)ls.get((u32)0).level[2]);
    return 0;
    }
