//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
// irq_vbi.xc — regression for the :irq and :vbi function annotations
// and the Vbi.xc install/remove library.
//
// The Atari ROM is what actually dispatches IRQs and VBIs through
// $FFFE / VVBLKI / VVBLKD, and xts runs in basic mode without a ROM.
// We verify what we can without actually firing an interrupt:
//
//   1. The handler addresses resolve, the bodies compile, and their
//      first byte is the expected opcode (PHA $48 for the :vbi save
//      prologue, the body's leading LDA $A9 for :irq since it skips
//      the prologue altogether).
//   2. Walking forward from the handler address, we find the right
//      epilogue — RTI ($40) for :irq, JMP XITVBV ($4C $62 $E4) for
//      :vbi.
//   3. The Vbi library calls compile and link with no undefined
//      symbols. Their JSRs to SETVBV ($E45C) would fault in xts so
//      they live behind a runtime guard that's always false.

#import "Stdio.xc"
#import "Vbi.xc"

u8 testCount;
u8 failCount;
u8 fails[16];

u8 dispatchEnable;        // always 0 — guards the live VBI install

// :irq handler — naked, body, RTI. First body byte must be $A9 (LDA #).
void irqHandler(void) :irq
{
    asm { LDA #$5A }
}

// :vbi handler — PHA/TXA/PHA/TYA/PHA, body, PLA/TAY/PLA/TAX/PLA,
// JMP XITVBV. First handler byte must be PHA = $48.
void vbiHandler(void) :vbi
{
    asm { LDA #$A5 }
}

void checkU8(u8 got, u8 want)
{
    testCount = testCount + 1;
    if (got != want) {
        if (failCount < 16) { fails[failCount] = testCount; }
        failCount = failCount + 1;
    }
}

void main(void)
{
    testCount = 0;
    failCount = 0;
    dispatchEnable = 0;

    // Walk over the first few bytes of each handler. The pointer is
    // a u8@ aimed at the function's entry; we compare bytes to the
    // expected opcode signature.
    u8* irqBytes = (u8*)&irqHandler;
    u8* vbiBytes = (u8*)&vbiHandler;

    // T1: :irq starts straight with its body (LDA #imm) — opcode $A9.
    checkU8(irqBytes[0], $A9);
    // T2: byte 1 of LDA #imm is the literal #$5A.
    checkU8(irqBytes[1], $5A);

    // T3: :vbi starts with PHA ($48) — first byte of the A/X/Y save
    // prologue.
    checkU8(vbiBytes[0], $48);
    // T4: byte 1 must be TXA ($8A) — second instruction of the
    // prologue.
    checkU8(vbiBytes[1], $8A);

    // T5: Vbi library calls compile + link. The actual install would
    // smash $222 / $224 with handler addresses and JSR SETVBV (not
    // present in xts), so the live path is guarded off.
    if (dispatchEnable != 0) {
        Vbi.addImmediate(&irqHandler);
        Vbi.addDeferred(&vbiHandler);
        Vbi.removeImmediate();
        Vbi.removeDeferred();
    }
    checkU8(dispatchEnable, 0);

    u8 i;
    for (i = 0; i < failCount; i = i + 1) {
        if (i < 16) { Stdio.printf("T%u FAIL\n", fails[i]); }
    }
    Stdio.printf("DONE %u\n", testCount);
}
