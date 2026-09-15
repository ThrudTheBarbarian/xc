// class_static_ivar.xc — `static` on an ivar means ONE copy for the class.
//
// The keyword parsed and was then thrown away, so the ivar became ordinary
// per-instance storage. That left a class that mixes a static ivar with
// instance methods reading two different variables through one name: a static
// method reached the class's `__sdata` block, an instance method reached the
// receiver's own field, and neither saw the other's writes.
//
// A static ivar now has no instance slot at all — it is a module global
// (`__sivar_<Class>_<name>`), shared by every instance and by the class's
// static methods, and inherited by subclasses the way the name scope already
// implied.
//
//   T1  a static ivar counts across instances (one copy, not one each)
//   T2  a static method and an instance method see the SAME variable
//   T3  a static ivar sits outside the instance layout — the instance's own
//       ivars still read and write correctly, per instance
//   T4  a constant initialiser runs once, at load time
//   T5  a subclass's methods reach the parent's static ivar
//   T6  two classes' identically-named statics stay distinct

#import "Stdio.xc"
#import "Assert.xc"

class Counter
{
    static u16 made;          // one copy for the class
    static u16 limit = 7;     // …with a load-time initial value
    u16 id;                   // per instance

    void init(void)
    {
        made = made + (u16)1;
        id   = made;
    }
    u16 myId(void)        { return id; }
    u16 seenByInstance(void) { return made; }      // instance method
    static u16 total(void)   { return made; }      // static method, same name
    static u16 cap(void)     { return limit; }
}

class Tally : Counter
{
    u16 own;
    void init(void) { own = (u16)100; }
    u16 seenBySubclass(void) { return made; }      // parent's static
}

class Other
{
    static u16 made;                                // distinct from Counter's
    void init(void) { made = made + (u16)10; }
    static u16 total(void) { return made; }
}

void main(void)
{
    Assert.isEqual(Counter.cap(), (u16)7);          // T4

    Counter* a = new Counter();
    Counter* b = new Counter();
    Counter* c = new Counter();

    Assert.isEqual(Counter.total(), (u16)3);        // T1 — one copy, three inits
    Assert.isEqual(a.seenByInstance(), (u16)3);     // T2 — instance sees it too
    Assert.isEqual(c.seenByInstance(), Counter.total());

    Assert.isEqual(a.myId(), (u16)1);               // T3 — per-instance ivar
    Assert.isEqual(b.myId(), (u16)2);
    Assert.isEqual(c.myId(), (u16)3);

    // `new Tally()` chains to Counter.init (auto super-init), so the shared
    // counter moves to 4 — the subclass writes the SAME variable.
    Tally* t = new Tally();
    Assert.isEqual(t.seenBySubclass(), (u16)4);     // T5 — inherited static

    Other* o = new Other();
    Assert.isEqual(Other.total(), (u16)10);         // T6 — a different variable
    Assert.isEqual(Counter.total(), (u16)4);

    Assert.summary();
}
