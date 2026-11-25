// The conforming method must be the same operator as the requirement: the
// same shape, with the operands in the same roles.
// xtc: error "class 'Vec2' conforms to 'Numeric', which requires 'plus' to be the operator 'self + o'; Vec2's plus is the operator 'self - o': change it to ':operator(self + o)'"
protocol Numeric
    {
    Numeric* plus(Numeric* o) :operator(self + o);
    }

class Vec2 <Numeric>
    {
    i32 x;
    Numeric* plus(Numeric* o) :operator(self - o) { return o; }
    }

i32 main(void) { return 0; }
