// callback_shapes.xc — the shapes the 0.5 documentation shows (LANGUAGE-SPEC
// §9A). Every example in that section is one of these, so a change that
// invalidates the docs turns this fixture red rather than leaving the spec
// quietly wrong.
//
// The reason it exists as a SEPARATE fixture from callback_decl.xc: that one
// pins the TYPE IDENTITY (the two spellings intern together). This one pins
// the SURFACE — where a callback may be written, which is what a reader
// copies. They fail for different reasons and neither implies the other.
//
//   T1  as a parameter — the callee calls back with no context argument
//   T2  as a return type
//   T3  a stored callback auto-zeroes when its receiver dies (no keyword)
//   T4  widening: a plain function, then a static method
//   T5  the empty value, `(callback RET(params))0` — the null idiom the
//       `block` spelling has always had, and which `callback` did NOT parse
//       until the 0.5 docs went to write it down
//   T6  identity: two callbacks naming one action are equal
//   T7  bound through a BASE pointer, still reaching the override
#import "Stdio.xc"

i32 triple(i32 n) { return n * (i32)3; }

class Counter
{
    i32 total;
    void init(void)      { total = (i32)0; }
    void add(i32 n)      { total = total + n; }
    static i32 quad(i32 n) { return n * (i32)4; }
}

// Separate from Counter only so its dealloc message belongs to T3 alone —
// Counter outlives main's body and would print one on the way out.
class Listener : Counter
{
    void dealloc(void) { Stdio.printf("T3 listener died\n"); }
}

class Timer
{
    callback tick void(i32 n);
    void init(void) { }
    void fire(i32 n)
    {
        if (tick) { tick(n); }
        else      { Stdio.printf("T3 no listener\n"); }
    }
}

class Base            { u16 tag(void) { return (u16)1;  } }
class Derived : Base  { u16 tag(void) { return (u16)42; } }

void twice(callback visit void(i32 x), i32 v)
{
    visit(v);
    visit(v);
}

callback op i32(i32 n) chooseOp(bool widen)
{
    if (widen) { return &triple; }
    return &Counter.quad;
}

i32 main(void)
{
    // T1: as a parameter.
    Counter* c = new Counter();
    twice(&c.add, (i32)5);
    Stdio.printf("T1 %d\n", c.total);

    // T2: as a return type.
    auto op = chooseOp(true);
    Stdio.printf("T2 %d\n", op((i32)7));

    // T3: a stored callback goes falsy when its receiver dies.
    Timer* t = new Timer();
    {
        Listener* listener = new Listener();
        t.tick = &listener.add;
        t.fire((i32)3);
        Stdio.printf("T3 %d\n", listener.total);
    }
    t.fire((i32)3);

    // T4: widening a plain function, then a static method.
    callback f i32(i32 n);
    f = &triple;
    Stdio.printf("T4 %d", f((i32)5));
    f = &Counter.quad;
    Stdio.printf(" %d\n", f((i32)5));

    // T5: the empty value.
    f = (callback i32(i32))0;
    Stdio.printf("T5 %d\n", (i32)(!f));

    // T6: identity.
    callback g void(i32 n);
    callback h void(i32 n);
    g = &c.add;
    h = &c.add;
    Stdio.printf("T6 %d", (i32)(g == h));
    h = &c.init;
    Stdio.printf(" %d\n", (i32)(g == h));

    // T7: bound through a base pointer.
    Derived* d = new Derived();
    Base*    b = d;
    callback tg u16(void);
    tg = &b.tag;
    Stdio.printf("T7 %d\n", tg());
    return 0;
}
