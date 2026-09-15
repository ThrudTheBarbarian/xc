// printf_typed_width.xc — type-directed printf width.
//
// `%d`/`%u`/`%x` format the argument at its KNOWN STATIC width: a 32-bit
// argument makes the compiler upgrade the conversion to its `l` form, so the
// full value prints instead of the low 16 bits. A genuinely 16-bit argument
// still uses the 16-bit read. So `%d` means "format this integer at whatever
// width it actually is".
//
// The 32-bit values here come from EXPLICIT casts. They used to come from
// `w * h` on two u16s, back when sub-word arithmetic was C-promoted to 32
// bits; same-width arithmetic now stays at its own width (private:docs/bugs/041), so
// `w * h` is a u16 multiply and wraps — which is what the last two lines pin.
#import "Stdio.xc"

void main(void)
{
    u16 w = 320;
    u16 h = 250;
    Stdio.printf("%d\n", (u32)w * (u32)h);   // 32-bit product: 80000
    u16 a = 200;
    u16 b = 100;
    Stdio.printf("%d\n", a + b);             // 16-bit: 300
    Stdio.printf("%d\n", (i16)-5);           // 16-bit signed, unchanged: -5
    Stdio.printf("%d %d\n", (u32)w * (u32)h, 42);  // 32-bit arg + trailing arg stays aligned
    Stdio.printf("%x\n", (u32)w * (u32)h);   // %x → %lx: 00013880
    i32 big = -100000;
    Stdio.printf("%d\n", big);               // i32 → %ld: -100000
    Stdio.printf("%u\n", (u16)40000);        // 16-bit unsigned, unchanged: 40000
    // Same-width arithmetic keeps its own width, so this WRAPS: 80000 & $FFFF.
    Stdio.printf("%d\n", w * h);             // 14464
}
