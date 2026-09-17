// new_init_arity_refused.xc — `new C(...)` must match an init.
//
// `new` used to accept any argument list. The arguments were lowered and
// handed to the allocator without ever being compared against the class's
// init parameters, so `new Holder()` on a class whose init REQUIRES a value
// ran no initialiser at all and left the field zero. Silent, and the wrong
// answer rather than a diagnostic.
//
// Too many arguments behaved the same way. Both are now rejected.
//xtc-flags: expect=sema-error
#import "Stdio.xc"

class Holder
    {
    u32 k;
    void init(u32 x) { k = x; }
    u32 get(void)    { return k; }
    }

i32 main(void)
    {
    Holder* h = new Holder();        // init requires one argument
    Stdio.printf("%lu\n", h.get());
    return 0;
    }
