// A bare call to a method of the enclosing class in a block literal means
// self.m(…), which a block cannot make: refused by name, as self.m(…) is,
// rather than as an undeclared function (#431). The same check covers par
// bodies; a block literal keeps this fixture to the check itself.
// xtc: error "a block cannot call the method 'twice'"
i32 main(void)
    {
    return 0;
    }

class Probe : Object
    {
    u32 twice(u32 v)
        {
        return v * 2;
        }

    void run(void)
        {
        block u32(u32 k) b = block u32(u32 k) { return twice(k); };
        }
    }
