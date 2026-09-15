//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
// inline asm (phase-171: arm64 backend assembles asm verbatim).
// heap_self_member_bank.xc — multi-bank correctness for ivar assigns
// inside method bodies.
//
// `child = new Inner()` inside Container.init() must store all THREE
// bytes of the resulting banked pointer into self.child (slot+1, +2,
// +3 of self). Earlier the codegen emitted only two STA (self),Y
// stores at offsets 1 and 2 — dropping the bank byte at offset 3.
// container.child then read back as bank=0 (whatever zero-init left
// in slot+3), so any later c.child.* access went through bank 0
// instead of the bank Inner physically lives in.
//
// The bug is invisible under "same-side" round-trips: write through
// container.child writes to bank 0 at the right offset, read through
// container.child reads from bank 0 at the same offset, and the
// value survives. To unmask it we deposit a distinct decoy byte at
// the bank-0 address via inline asm AFTER the user-level write. If
// the user-level write actually went to bank 0, the decoy clobbers
// it and the readback fails. If it went to the real heap bank, the
// decoy is harmless.
//
// xt-heap-only — the inline-asm decoy writes $83 directly. xe-heap
// would need PORTB manipulation; the same codegen fix applies, but
// the test harness is target-specific.

#import "Stdio.xc"
#import "Assert.xc"

class Inner { u16 v; }
class Container {
    banked:Inner* child;
    void init(void) { child = new Inner(); }
}

void main(void)
{
    Assert.reset();

    // Force Inner to land somewhere other than bank 0.
    u8* filler = new u8[4080];

    banked:Container* c = new Container();
    c.child.v = $CAFE;

    // Decoy: scribble distinct bytes into bank 0 at the address Inner
    // would occupy if its bank byte had been silently dropped to 0.
    // $6004 = first payload byte after the 4-byte heap header in any
    // bank. $6005-$6006 covers Inner.v.
    asm {
        LDA $83
        PHA
        LDA #$00
        STA $83
        LDA #$99
        STA $6005
        STA $6006
        PLA
        STA $83
    }

    // Survives iff the user-level write actually addressed Inner's
    // real bank, not bank 0.
    Assert.isEqual(c.child.v, $CAFE);   // T1

    Stdio.printf("v=%u\n", c.child.v);

    delete filler;
    Assert.summary();
    return;
}
