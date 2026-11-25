// A class that conforms to a protocol requiring an operator must define its
// method as that operator.
// xtc: error "class 'Vec2' conforms to 'Numeric', which requires 'plus' to be the operator 'self + o'; add ':operator(self + other)' to Vec2's plus"
protocol Numeric
    {
    Numeric* plus(Numeric* o) :operator(self + o);
    }

class Vec2 <Numeric>
    {
    i32 x;
    Numeric* plus(Numeric* other) { return other; }
    }

i32 main(void) { return 0; }
