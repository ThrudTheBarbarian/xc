#use Stdio
//xtc-na: xt6502 — the 16 live u64 accumulators need a 415-byte SP frame, over the 119-byte budget; automatic frame splitting is a future task (STACK-ABI §7)
// u64_spill_add_imm.xc — blewit F10 emission half: a SPILLED u64 loop
// counter whose `i + 1` folds into the imm12 form materialised through a
// hard-coded w16 scratch — `add x10, w16, #1`, invalid AArch64 (and a
// TRUNCATING materialise). The 16 live accumulators are what evict the
// counter from its home; the selfhost port already sized the scratch by
// the result type, so this also pins original/port agreement.
struct H { u8 tag; u64* words; }
i32 main() {
    u64 st[4];
    H h; h.words = &st[0];
    // Enough live u64 accumulators that the loop counter loses its home:
    // the add-imm fold then materialises it through the scratch, which
    // must be X-named for a 64-bit result.
    u64 a0=1; u64 a1=2; u64 a2=3; u64 a3=4; u64 a4=5; u64 a5=6;
    u64 a6=7; u64 a7=8; u64 a8=9; u64 a9=10; u64 aa=11; u64 ab=12;
    u64 ac=13; u64 ad=14; u64 ae=15; u64 af=16;
    for (u64 i = 0; i < 4; i = i + 1) {
        h.words[i] = i + 100;
        a0=a0+i; a1=a1+a0; a2=a2+a1; a3=a3+a2; a4=a4+a3; a5=a5+a4;
        a6=a6+a5; a7=a7+a6; a8=a8+a7; a9=a9+a8; aa=aa+a9; ab=ab+aa;
        ac=ac+ab; ad=ad+ac; ae=ae+ad; af=af+ae;
    }
    printf("w3=%ld af=%ld\n", (u32)h.words[3], (u32)(af & 0xFFFF));
    return 0;
}
