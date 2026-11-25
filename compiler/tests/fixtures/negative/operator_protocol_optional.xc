// An operator requirement cannot be optional: `a + b` would have nothing to
// call where a class leaves it out.
// xtc: error "an operator requirement cannot be optional; make 'plus' a required method or drop ':operator(...)'"
protocol Numeric
    {
    optional Numeric* plus(Numeric* o) :operator(self + o);
    }

i32 main(void) { return 0; }
