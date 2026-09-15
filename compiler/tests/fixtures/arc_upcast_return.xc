// arc_upcast_return.xc — a `new` returned through an UPCAST must keep its +1.
//
// `return (P@)new C()` (upcast a fresh object to a protocol / Object pointer)
// lowers the `new` to an owned temp and the cast to a Bitcast. The scope-exit
// owned-temp sweep must follow the value THROUGH the cast — before the fix it
// released the pre-cast temp, freeing the object, so the caller received a
// dangling pointer and crashed the instant it dispatched a method on it.
//
//   T1  a protocol method dispatched on the upcast-returned object runs (the
//       object is still alive — no premature free)
//   T2  the object is freed exactly once (no leak, no double free)

#import "Stdio.xc"
#import "Assert.xc"

protocol Pingable { i32 ping(i32 x); }

class Widget : Object <Pingable>
{
    i32 seed;
    void init(void) { seed = 100; }
    i32 ping(i32 x) { return seed + x; }
    void dealloc(void) { freed = freed + 1; }
}

u16 freed;

// Factory returns the fresh object UPCAST to the protocol — type erased.
Pingable* makeWidget(void) { return (Pingable*)new Widget(); }

void useIt(void)
{
    Pingable* p = makeWidget();     // adopt the +1 through the upcast
    Assert.isEqual(p.ping(5), 105); // dispatch on the erased pointer — must be alive
    // scope exit releases p once → dealloc fires once
}

void main(void)
{
    Assert.reset();
    freed = 0;

    useIt();
    Assert.isEqual(freed, 1);       // freed exactly once

    Assert.summary();
    return;
}
