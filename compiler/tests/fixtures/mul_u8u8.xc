// mul_u8u8.xc — same-width arithmetic stays at that width.
//
// `u8 * u8` is a u8 multiply and WRAPS at 8 bits: 54*54 = 2916, and
// 2916 & $FF = 100. It wraps whether the result is stored into a u8 or into
// something wider, because the operator's type comes from its OPERANDS and
// widening is what the ASSIGNMENT does afterwards — there is no C-style
// promotion to int (private:docs/bugs/041).
//
// This fixture used to assert the opposite, and said so: "arithmetic on
// sub-word integers is computed at 32-bit (like C)". That was the compiler's
// behaviour and it contradicted the language spec; the
// corpus never caught the contradiction because nothing pinned
// `u16 wide = <u8> * <u8>` — the one case where the two rules disagree.
//
// To get the true product, widen the OPERANDS.
#import "Stdio.xc"

void main(void)
{
    u8  t = 54;
    u8  wrap = t * t;               // u8 multiply: 2916 & $FF = 100
    u16 wide = t * t;               // STILL a u8 multiply: 100, not 2916
    u16 real = (u16)t * (u16)t;     // widen the operands: 2916

    Stdio.printf("%d %d %d\n", (i16)wrap, (i16)wide, (i16)real);
}
