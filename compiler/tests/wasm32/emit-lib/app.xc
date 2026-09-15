// app.xc — W2 fixture app: cross-module new / method / protocol dispatch /
// downcast / bound method against libTheLib.wasm — plus an APP subclass of
// a LIBRARY class (its vtable parent link is library data, patched by
// $__xtc_fixup_imports before the module inits run).
#import "Stdio.xc"
#import <TheLib>

typedef i32 pingfn_t(i32);

class ExtraLoud : Greeter
    {
    i32 greet(i32 n)
        {
        return (self.base + n) * (i32)3;
        }
    }

    void
    main(void)
    {
    Greeter* g = new Greeter();
    Stdio.printf("greet=%ld\n", g.greet((i32)2)); // 42

    Pingable* p = (Pingable*)g;
    Stdio.printf("ping=%ld\n", p.ping((i32)10)); // 51

    Greeter* l = makeLoud();
    Stdio.printf("loud=%ld\n", l.greet((i32)5)); // 90

    LoudGreeter* down = (LoudGreeter* ?)l;
    Stdio.printf("down=%d\n", down != (LoudGreeter*)0 ? (i32)1 : (i32)0); // 1
    LoudGreeter* not = (LoudGreeter* ?)g;
    Stdio.printf("notdown=%d\n", not!= (LoudGreeter*)0 ? (i32)1 : (i32)0); // 0

    // An APP subclass of a LIBRARY class: dispatch reaches the app override,
    // and the ancestry downcast walks the parent link ACROSS the boundary.
    Greeter* x = (Greeter*)new ExtraLoud();
    Stdio.printf("extra=%ld\n", x.greet((i32)2)); // 126
    Greeter* asG = (Greeter* ?)x;
    Stdio.printf("xdown=%d\n", asG != (Greeter*)0 ? (i32)1 : (i32)0); // 1

    // A `^` bound on a LIBRARY object: the code word is a funcref table
    // index read from the lib's (rebased) vtable at run time.
    pingfn_t ^ h = &l.greet;
    Stdio.printf("bound=%ld\n", h((i32)3)); // 86 (runtime override)

    g.say(); // greeter base=40
    }
