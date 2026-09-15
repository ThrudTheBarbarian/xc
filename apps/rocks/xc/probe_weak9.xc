// probe_weak9.xc — after the 036 fix: who consumes a returned +1?
//
// MEASURED on the compiler installed 2026-09-06 13:18, WITH the 036 fix in:
//
//   ok        strongGetter() discarded / stored              (the control)
//   ok        `Obj* f(void) { return w; }` discarded/stored  <- THE 036 SHAPE: fixed
//   LEAK +1   `weak: Obj* f(void)` — an explicitly weak-DECLARED return,
//             and it leaks whether the result is stored or thrown away
//
// So the fix is right where it matters: a strong-signature method returning a
// weak field now balances, which is the shape Rocks had and the shape the bug
// was about.  What is left is the corner: when the RETURN TYPE ITSELF is
// declared weak, the callee retains but nothing ever releases, because the
// caller keys its release off the value's type and skips weak ones.  The
// two ends disagree about who owns it.
//
// There are no weak-declared return types anywhere in frameworks/uxkit or
// apps/rocks, so this costs nothing today; it is recorded because "returns
// weak" is expressible and silently leaks.
//
// Weak-typed return vs strong-typed return: who consumes the +1?
// Every object here has exactly ONE owner that dies inside the scope, so a
// leaked reference is visible.  (An object kept alive by something else makes
// this instrument blind — a leak and a balance look identical.)
#import <Stdio.xc>
i32 gLive;
class Obj : Object
    {
    void init(void)
        {
        gLive = gLive + (i32)1;
        }
    void dealloc(void)
        {
        gLive = gLive - (i32)1;
        }
    } class H : Object
    {
    weak : Obj* w;
    Obj* s;
    void init(void)
        {
        w = (Obj*)0;
        s = (Obj*)0;
        }
    // weak-DECLARED return
    weak : Obj* getWeak(void)
        {
        return w;
        }
    // STRONG-declared return of a weak field (the 036 shape)
    Obj* getWeakAsStrong(void)
        {
        return w;
        }
    // strong-typed return
    Obj* getStrong(void)
        {
        return s;
        }
    } i32 gFails;
void expect(u8* what, i32 before)
    {
    i32 d = gLive - before;
    if (d == (i32)0)
        {
        Stdio.printf("  ok            %s\n", what);
        }
    else if (d > (i32)0)
        {
        Stdio.printf("  LEAK (+%d)     %s\n", (i16)d, what);
        gFails = gFails + (i32)1;
        }
    else
        {
        Stdio.printf("  OVER-REL (%d) %s\n", (i16)d, what);
        gFails = gFails + (i32)1;
        }
    }
// STRONG-typed getter, for comparison: h.s owns it, h dies at scope exit.
void strongDiscard(void)
    {
    H* h = new H();
    h.s = new Obj();
    h.getStrong();
    }
void strongStore(void)
    {
    H* h = new H();
    h.s = new Obj();
    Obj* g = h.getStrong();
    }
// WEAK-typed getter: o owns it, both die at scope exit.
void weakNoCall(void)
    {
    H* h = new H();
    Obj* o = new Obj();
    h.w = o;
    }
void weakDiscard(void)
    {
    H* h = new H();
    Obj* o = new Obj();
    h.w = o;
    h.getWeak();
    }
void weakStore(void)
    {
    H* h = new H();
    Obj* o = new Obj();
    h.w = o;
    Obj* g = h.getWeak();
    }
void weakTwice(void)
    {
    H* h = new H();
    Obj* o = new Obj();
    h.w = o;
    h.getWeak();
    h.getWeak();
    }
void wasDiscard(void)
    {
    H* h = new H();
    Obj* o = new Obj();
    h.w = o;
    h.getWeakAsStrong();
    }
void wasStore(void)
    {
    H* h = new H();
    Obj* o = new Obj();
    h.w = o;
    Obj* g = h.getWeakAsStrong();
    }

void main(void)
    {
    gLive = (i32)0;
    gFails = (i32)0;
    i32 b;
    Stdio.printf("-- strong-typed return (the control) --\n");
    b = gLive;
    strongDiscard();
    expect((u8*)"strongGetter(), discarded       ", b);
    b = gLive;
    strongStore();
    expect((u8*)"strongGetter(), stored in local ", b);
    Stdio.printf("-- weak-typed return --\n");
    b = gLive;
    weakNoCall();
    expect((u8*)"no call at all                  ", b);
    b = gLive;
    weakDiscard();
    expect((u8*)"weakGetter(), discarded         ", b);
    b = gLive;
    weakStore();
    expect((u8*)"weakGetter(), stored in local   ", b);
    b = gLive;
    weakTwice();
    expect((u8*)"weakGetter() called TWICE       ", b);
    Stdio.printf("-- STRONG-declared return of a weak field (the actual 036 shape) --\n");
    b = gLive;
    wasDiscard();
    expect((u8*)"return w; (strong sig), discarded", b);
    b = gLive;
    wasStore();
    expect((u8*)"return w; (strong sig), stored  ", b);
    if (gFails == (i32)0)
        {
        Stdio.printf("PASS\n");
        }
    else
        {
        Stdio.printf("FAIL: %d\n", (i16)gFails);
        }
    }
