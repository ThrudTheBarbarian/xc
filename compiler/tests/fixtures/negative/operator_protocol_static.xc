// A protocol's static member is not called on an object, so it cannot be an
// operator requirement.
// xtc: error "a protocol's static member cannot be an operator; make 'plus' an instance method or drop ':operator(...)'"
protocol Numeric
    {
    static Numeric* plus(Numeric* a, Numeric* b) :operator(a + b);
    }

i32 main(void) { return 0; }
