//xtc-na: arm9,m68k,xt6502,x86_64,win64 — uses inline arm64 assembly
// asm_writeback_pre.xc — a pre-index operand with writeback, `[xN, #i]!`, in
// inline asm (#359). The source lexer re-spaces an asm body token by token,
// so `[x1, #8]!` reached the assembler as `[ x1,#8 ] !`, which it refused as
// an unterminated memory operand. Two pre-index loads walk the array, a
// pre-index store writes past them, and the base register's final value
// shows each writeback happened.

#import "Stdio.xc"

i32 main(void)
    {
    u64 a[4];
    a[0] = (u64)10;
    a[1] = (u64)20;
    a[2] = (u64)30;
    a[3] = (u64)0;
    u64* p = &a[0];
    u64 sum = (u64)0;
    u64 end = (u64)0;
    asm
    {
        ldr x1, [p]
        ldr x2, [x1, #8]!
        ldr x3, [x1, #8]!
        add x2, x2, x3
        str x2, [x1, #8]!
        str x2, [sum]
        str x1, [end]
    }
    Stdio.printf("%llu %llu %llu\n", sum, a[3], (end - (u64)p) / (u64)8);
    return 0;
    }
