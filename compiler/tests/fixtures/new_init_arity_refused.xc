//xtc-flags: expect=sema-error
// `new C(args)` whose arguments match no init must be refused.
//
// The resolver used to collect init candidates by arity and, when none
// matched, fall through silently: nothing was stamped, the lowering runs an
// init only when sema stamped one, so the object was allocated, no
// initialiser ran, and every field read back zero.
//
// `new C()` with NO arguments is a different thing and stays legal — it is
// the allocate-and-zero form, used deliberately before initialising by hand
// (see ivar_coalesce.xc). Only supplied arguments that match nothing are an
// error.
#import "Stdio.xc"

class Holder
    {
    u32 x;
    void init(u32 v) { x = v; }
    u32 get(void)    { return x; }
    }

i32 main(void)
    {
    Holder* h = new Holder((u32)1, (u32)2);   // init takes ONE argument
    Stdio.printf("%lu\n", h.get());
    return 0;
    }
