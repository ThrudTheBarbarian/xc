// TheLib.xc — arm64 --emit-lib fixture: a class with a constructor, an
// instance method, a subclass and a free function. Compiled into
// libTheLib.dylib and consumed by app.xc.
#import "Stdio.xc"

class Greeter : Object
    {
    i32 base;
    void init(void)
        {
        self.base = (i32)40;
        }
    i32 greet(i32 n)
        {
        return self.base + n;
        }
    void say(void)
        {
        Stdio.printf("greeter base=%ld\n", self.base);
        }
    }

    class LoudGreeter : Greeter
    {
    i32 greet(i32 n)
        {
        return (self.base + n) * (i32)2;
        }
    }

    Greeter*
    makeLoud(void)
    {
    return (Greeter*)new LoudGreeter();
    }
i32 twice(i32 n)
    {
    return n * (i32)2;
    }
