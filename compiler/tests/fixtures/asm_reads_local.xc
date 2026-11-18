//xtc-na: xt6502,m68k,arm9,x86_64,win64,wasm32 — the asm body is AArch64
// asm_reads_local.xc — a local that only an asm block reads keeps its stores
// at -O2 and above (#361). Inline asm names locals inside its text, not as IR
// operands, so dead-code's write-only-locals rule took `w` for never read and
// dropped its store: the asm loaded garbage. The same rule emptied every
// store Gfx8's asm reads on xt6502, so the gfx8 programs drew nothing.
#import "Stdio.xc"
u64 pass(u64 a)
    {
    u64 w = a * (u64)3;
    u64 v = (u64)0;
    asm
    {
        ldr x1, [w]
        str x1, [v]
    }
    return v;
    }
i32 main(void)
    {
    Stdio.printf("%llu\n", pass((u64)14));
    return 0;
    }
