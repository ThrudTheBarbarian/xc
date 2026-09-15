// app.xc — the client: `new` of a library class, a method call, a virtual call
// through a library-created subclass, an APP subclass of a library class, and
// a free function.
#import "Stdio.xc"
#import <TheLib>

class ExtraLoud : Greeter
    {
    i32 greet(i32 n)
        {
        return (self.base + n) * (i32)3;
        }
    }

    i32
    main(void)
    {
    Greeter* g = new Greeter();
    Stdio.printf("greet=%ld\n", g.greet((i32)2)); // 42
    Greeter* l = makeLoud();
    Stdio.printf("loud=%ld\n", l.greet((i32)5)); // 90
    Greeter* x = (Greeter*)new ExtraLoud();
    Stdio.printf("extra=%ld\n", x.greet((i32)2)); // 126
    Stdio.printf("twice=%ld\n", twice((i32)21));  // 42
    g.say();                                      // greeter base=40
    return 0;
    }
