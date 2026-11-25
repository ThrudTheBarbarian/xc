//xtc-flags: expect=sema-error
// A free call whose value initialises a variable checks its arguments like a
// call on its own: the call used to be resolved by its return type alone, so
// an unrelated class passed for the parameter compiled.
// Refused: argument 1 of 'f': 'B' is not a subclass of 'A'

class A { i32 x; }
class B { i32 y; }

i32 f(A* a) { return a.x; }

i32 main(void)
    {
    B* b = new B();
    i32 r = f(b);
    return r;
    }
