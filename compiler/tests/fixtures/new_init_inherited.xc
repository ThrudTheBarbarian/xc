// new_init_inherited.xc — a subclass with no init of its own uses its
// parent's.
//
// `class Sub : Base { }` inherits Base's methods, and `new Sub(7)` must run
// Base's init the way `new Base(7)` does. It used to allocate without running
// any initialiser, so the field read back zero while the program compiled
// clean. The init symbol belongs to the class that DECLARES it, so resolving
// this has to name Base, not Sub.
#import "Stdio.xc"

class Base
    {
    u32 k;
    void init(u32 x) { k = x; }
    u32 get(void)    { return k; }
    }

class Sub : Base { }

i32 main(void)
    {
    Base* b = new Base((u32)7);
    Sub*  s = new Sub((u32)9);
    Stdio.printf("base=%lu sub=%lu\n", b.get(), s.get());
    return 0;
    }
