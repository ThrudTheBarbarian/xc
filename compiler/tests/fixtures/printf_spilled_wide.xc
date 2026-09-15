//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
// xt6502 varargs packer's spilled-wide-identifier handling. arm64's
// vararg path is AAPCS64 register/stack passing through clang — a
// completely different mechanism that this scaffolding doesn't apply
// to. The printf-output check below is meaningful only on xt6502.
//
// printf_spilled_wide.xc — varargs packer must handle spilled
// u32 / float / double identifiers. Pre-fix the
// emitVarargsPack identifier branch checked globalAddresses
// for ZP-resident vars but had no spillLabels fallback for
// widths > 2, so a spilled float arg was silently skipped and
// printf read whatever stale bytes happened to live in the
// buffer slot. The user-visible symptom: any %f arg whose
// expression ZP slot got spilled printed as "1.000000"
// (the buffer's leftover zeros decoded as the xtc float 1.0).
//
// We force ZP pressure by declaring 13+ u16 locals; that
// pushes the float result out of ZP and into _spill_f3. The
// printed value is then determined by whether the packer
// honours the spilled-load path or skips it.

#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    u16 z0 = 1; u16 z1 = 2; u16 z2 = 3; u16 z3 = 4;
    u16 z4 = 5; u16 z5 = 6; u16 z6 = 7; u16 z7 = 8;
    u16 z8 = 9; u16 z9 = 10; u16 zA = 11; u16 zB = 12;
    u16 zC = 13;

    // float identifier — pre-fix this skipped the buffer push
    // and printf read zeros from the buffer (xtc float
    // {0,0,0,0,0} = 1.0). Stage the float via the printf
    // packer; reading byte 1 of the value back afterward
    // confirms the wide identifier was actually pushed.
    float f = 3.566666;
    Stdio.printf("f=%f\n", f);
    // For p=%lu f=%f the packer stores slot 0 (dummy:u32) then
    // slot 1 (f:float). New-IR slot stride is 8 bytes, so slot 1
    // begins at `___xtc_va_buf + 8`. For f = 3.566666 the xtc
    // float byte 1 is the exponent (~$02 for 2^2 ≈ 4 magnitude);
    // for IEEE 754 single on arm64 byte 1 is the middle mantissa
    // byte (~$7F). Either way: non-zero on a successfully-packed
    // value, $00 on the stale-zero "1.0" pattern.
    u32 dummy = 0;
    Stdio.printf("p=%lu f=%f\n", dummy, f);
    u8 fbyte1;
    asm {
#if ARCH_6502
        LDA ___xtc_va_buf+9
        STA fbyte1
#elif ARCH_arm64
        ldrb w0, [f]
        strb w0, [fbyte1]
#endif
    }
    Assert.isNotEqual((u16)fbyte1, 0);   // T1 — non-zero byte of f

    // u32 identifier — same packer branch handles it. byte 0 of
    // u = $4E on both backends (little-endian u32, identical
    // representation). For xt6502 read it from slot 1 byte 0
    // (`___xtc_va_buf + 8`); for arm64 read directly from u's
    // own stack-slot byte 0.
    u32 u = 12345678;
    Stdio.printf("u=%lu\n", u);
    Stdio.printf("p=%lu u=%lu\n", dummy, u);
    u8 ubyte0;
    asm {
#if ARCH_6502
        LDA ___xtc_va_buf+8
        STA ubyte0
#elif ARCH_arm64
        ldrb w0, [u]
        strb w0, [ubyte0]
#endif
    }
    Assert.isEqual((u16)ubyte0, $4E);    // T2 — low byte of u
    Assert.isEqual(z0,  1);              // T3 — zp pad survived
    Assert.isEqual(z6,  7);              // T4
    Assert.isEqual(zC, 13);              // T5

    Stdio.printf("DONE 5\n");
    return;
}
