// A bare call to a method of the enclosing class in a par body means
// self.m(…), which a block cannot make: refused by name, as self.m(…) is,
// rather than as an undeclared function (#431).
// xtc: error "a block cannot call the method 'twice'"
#import "Stdio.xc"
#import "Par.xc"

class Probe : Object
    {
    u32 run(u32 n)
        {
        u32 s = 0;
        par :reduce(+ s)
            {
            for (u32 k in 0..n)
                s = s + twice(k);
            }
        return s;
        }

    u32 twice(u32 v)
        {
        return v * 2;
        }
    }

i32 main(void)
    {
    Probe* p = new Probe();
    Stdio.printf("%u\n", p.run(4));
    return 0;
    }
