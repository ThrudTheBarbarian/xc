// mul64_imm.xc — a 64-bit multiply by a >32-bit CONSTANT keeps its top
// bits (task #27). x86-64's `imul r64, r/m64, imm32` sign-extends a
// 32-bit immediate — there is no imm64 form — and the constant-multiplier
// fast path used it for ANY immediate: x * 0x100000001B3 (the FNV-1a 64
// prime) silently became x * 0x1B3, so every 64-bit content hash blewit
// computed on x86_64 disagreed with arm64. Wide multipliers must ride a
// register. Sentinels chosen so the TOP 32 bits of the product matter.
#import "Stdio.xc"
#import "Foundation.xc"

u64 g = (u64)3;

i32 main(void)
{
    u64 a = (u64)3;
    u64 prime = (u64)1099511628211;
    Stdio.printf("%s\n", String.withU64(a * (u64)1099511628211).cString());
    Stdio.printf("%s\n", String.withU64(a * prime).cString());
    Stdio.printf("%s\n", String.withU64(g * (u64)1099511628211).cString());
    Stdio.printf("%s\n", String.withU64((u64)14695981039346656037 * (u64)3).cString());
    return 0;
}
