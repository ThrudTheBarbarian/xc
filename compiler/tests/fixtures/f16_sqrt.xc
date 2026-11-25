// f16_sqrt.xc — the square root of a 16-bit float through Math: the value
// widens to f32 exactly, Math.sqrt rounds once to f32, and the cast rounds
// once to the type. f32 has more than twice the precision of f16 and bf16
// plus two bits, so the result is the correctly rounded square root. Checked
// against numpy's float16 square root and an f32 result rounded to bf16.
#import "Stdio.xc"
#import "Math.xc"

u16 hb(f16 h) { return *(u16*)&h; }
u16 bb(bf16 g) { return *(u16*)&g; }

i32 main(void)
{
    f16 y = 2.71828;
    f16 k = 2048;
    f16 t = 0.0001;
    bf16 g = 3.14159;
    Stdio.printf("sqrt %x %x %x\n", hb((f16)Math.sqrt((f32)y)), hb((f16)Math.sqrt((f32)k)), hb((f16)Math.sqrt((f32)t)));
    Stdio.printf("bsqrt %x\n", bb((bf16)Math.sqrt((f32)g)));
    return 0;
}
