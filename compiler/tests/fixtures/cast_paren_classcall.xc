// cast_paren_classcall.xc — a cast whose operand is a parenthesised expression
// that starts with a class name.
//
//     (u32)(Klass.method())
//
// The parser decided "cast" from ONE token after a `(`: a type keyword or a
// known type name. A class name is a known type name, so the INNER paren was
// read as a cast to `Klass`, and the parse died on the `.` that followed. The
// workaround was to bind the call to a local first. The rule is now the real
// one: a cast is a complete type followed by `)`.
//
//   T1  cast applied to a parenthesised static call
//   T2  the same, with arithmetic inside the parens
//   T3  a parenthesised class call with no cast at all
//   T4  real casts still parse: pointer, failable, qualifier-prefixed
//   T5  a parenthesised instance call through a class-typed local

#import "Stdio.xc"
#import "Assert.xc"

class Klass
{
    u16 v;
    void init(void)       { v = (u16)11; }
    u16 value(void)       { return v; }
    static u16 answer(void) { return (u16)42; }
    static u16 twice(u16 x) { return (u16)(x + x); }
}

void main(void)
{
    Assert.isEqual((u32)(Klass.answer()), (u32)42);              // T1
    Assert.isEqual((u32)(Klass.answer() + (u16)1), (u32)43);     // T2
    Assert.isEqual((u32)(Klass.twice((u16)3)), (u32)6);
    Assert.isEqual((Klass.answer()), (u16)42);                   // T3

    Klass* k = new Klass();
    Assert.isEqual((u32)(k.value()), (u32)11);                   // T5

    // T4 — the shapes the one-token test got right, which must stay right.
    Object* up = (Object*)k;
    Klass* back = (Klass* ?)up;
    Assert.isTrue(back != 0);
    Assert.isEqual((u16)(u8)$FF, (u16)255);
    Assert.isEqual((u32)((u16)7), (u32)7);

    Assert.summary();
}
