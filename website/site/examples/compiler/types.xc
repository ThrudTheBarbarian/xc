// types.xc — the scalar types, integer width rules, and pointers.
#import "Foundation.xc"
#import "Stdio.xc"

i32 main(void)
{
    // Widths are in the name. i = signed, u = unsigned.
    //   i8/u8  i16/u16  i32/u32  i64/u64   bool   float   double
    // `string` is an alias for u8*.
    u8  small = (u8)200;
    u16 mid   = (u16)60000;
    i32 wide  = (i32)-100000;
    u64 huge  = (u64)1 << (u64)40;      // 64-bit works on every target
    // printf's width contract: %d is 16-BIT and %ld is 32-bit, and both are
    // signed — which is why 60000 in a u16 prints as -5536. Cast to the width
    // you want to see.
    Stdio.printf("u8=%d u16=%d (as i32 %ld) i32=%ld\n", small, mid, (i32)mid, wide);
    Stdio.printf("2^40 = %ld:%ld (hi:lo)\n", (u32)(huge >> (u64)32), (u32)huge);

    // Same-width arithmetic stays at that width: u8 + u8 wraps at 8 bits, so
    // 200 + 100 is 44 rather than 300. There is no C-style "promote everything
    // to int" step.
    u8 a = (u8)200, b = (u8)100;
    u8  wrapped = a + b;                 // 300 & 0xFF = 44
    // Widening the DESTINATION does not help — `u16 w = a + b;` is still a u8
    // add, and still 44. To get the true sum, widen the OPERANDS.
    u16 widened = (u16)a + (u16)b;       // 300
    Stdio.printf("u8 200+100 -> %d   widened -> %d\n", (u16)wrapped, widened);

    // Literal prefixes: $ hex, % binary, _ ignored anywhere in a literal.
    u16 hex = $BEEF;
    u8  bin = %1010_0101;
    u32 big = 1_000_000;
    Stdio.printf("hex=%ld bin=%d big=%ld\n", (i32)hex, (u16)bin, big);

    // Pointers use *, & takes an address, -> is sugar for (*p).field.
    u16 value = (u16)1234;
    u16* p = &value;
    Stdio.printf("*p = %d\n", *p);
    *p = (u16)4321;
    Stdio.printf("value now %d\n", value);

    // The sigil binds to the TYPE, so this declares TWO pointers — unlike C,
    // where `u16* x, y` gives you a pointer and an integer.
    u16* x, y;
    x = &value; y = &value;
    Stdio.printf("both pointers: %d %d\n", *x, *y);

    // bool, and float/double.
    bool ok = true;
    float f = 1.5;
    double d = 3.1d;
    Stdio.printf("bool=%d float=%f double=%lf\n", ok ? (u16)1 : (u16)0, f, d);
    return 0;
}
