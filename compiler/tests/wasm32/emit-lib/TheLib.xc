// TheLib.xc — W2 fixture library: a class with a method, a protocol
// conformance, and a subclass. Compiled with --emit-lib into libTheLib.wasm.
#import "Stdio.xc"

protocol Pingable
    {
    i32 ping(i32 x);
    }

class Greeter : Object<Pingable>
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
    i32 ping(i32 x)
        {
        return self.base + x + (i32)1;
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
