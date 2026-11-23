// The bitwise (& | ^), shift (<< >>) and rotate (<: :>) operators, each
// defined on a class, with their built-in precedence: `a | b & a ^ b << 1`
// groups as `a | ((b & a) ^ (b << 1))`.
#import <Stdio.xc>

class Bits
    {
    i32 v;
    static Bits* of(i32 x) { Bits* n = new Bits(); n.v = x; return n; }
    Bits* band(Bits* o) :operator(self & o) { return Bits.of(v & o.v); }
    Bits* bor(Bits* o)  :operator(self | o) { return Bits.of(v | o.v); }
    Bits* bxor(Bits* o) :operator(self ^ o) { return Bits.of(v ^ o.v); }
    Bits* shl(i32 n)    :operator(self << n) { return Bits.of(v << n); }
    Bits* shr(i32 n)    :operator(self >> n) { return Bits.of(v >> n); }
    Bits* rol(i32 n)    :operator(self <: n) { u8 b = (u8)v; return Bits.of((i32)(b <: (u8)n)); }
    Bits* ror(i32 n)    :operator(self :> n) { u8 b = (u8)v; return Bits.of((i32)(b :> (u8)n)); }
    }

i32 main(void)
    {
    Bits* a = Bits.of(12);
    Bits* b = Bits.of(5);
    Stdio.printf("& %d\n", (a & b).v);
    Stdio.printf("| %d\n", (a | b).v);
    Stdio.printf("^ %d\n", (a ^ b).v);
    Stdio.printf("<< %d\n", (a << 3).v);
    Stdio.printf(">> %d\n", (a >> 2).v);
    Stdio.printf("prec %d\n", (a | b & a ^ b << 1).v);
    Stdio.printf("<: %d\n", (Bits.of(129) <: 1).v);
    Stdio.printf(":> %d\n", (Bits.of(129) :> 1).v);
    return 0;
    }
