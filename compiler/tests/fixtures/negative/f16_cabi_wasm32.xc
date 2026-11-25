// wasm32's C has no _Float16 or __bf16, so a bodyless variadic (a C callee)
// cannot take or return f16 or bf16 there.
// xtc: target wasm32
// xtc: error "a C-ABI function cannot take or return f16 or bf16 on this target ('hsum')"
#import "Stdio.xc"

f16 hsum(i32 n, f16 first, ...);

void main(void)
{
    f16 h = 1.5;
    Stdio.printf("%g\n", hsum(1, h));
}
