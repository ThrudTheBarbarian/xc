// global-init — pins initialised-global lowering. A simple
// `u16 g = $1234;` plus a negated literal (`i16 = -100`) and
// a binary-folded expression (`u32 = 100 * 1000`) ensures the
// folder handles literal, unary-neg, and binary-mul shapes.
// Reads emit AddrOf + Load against the symbol whose
// initialBytes payload the backend bakes in.
u16 gW = $1234;
i16 gI = -100;
u32 gExpr = 100 * 1000;

u16 read_gw(void)
    {
    return gW;
    }
