//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
// (phase-171: arm64 backend now assembles asm verbatim).
// heap_ivar_array.xc — banked-pointer ivar arrays.
//
// `class Set { banked:Slot@ items[N]; ... }` — inline array of
// banked-pointer ivars. Three working paths covered here:
//
//   - Direct subscript-store `items[i] = expr` from inside the
//     class's methods. Widths 1-4 wired; this fixture exercises
//     width 3 (banked:T@). Bank source is shape-aware (new-expr
//     → _alloc_bank, banked-placement identifier → slot+2 of the
//     source, fallback heap_bank_first).
//
//   - Subscript-load `items[i]` at constant index, returned from
//     a method as `banked:T@`. Reads all three bytes via
//     (self),Y at the right ivar offset, lands them in A=lo /
//     X=hi / Y=bank per the return convention.
//
//   - Y preservation through emitFrameRestore for 3-byte banked-
//     pointer return values. Without this the bank byte gets
//     clobbered by the frame-restore PLAs and the caller picks
//     up garbage.
//
// Cross-bank decoy: wipe bank 0 between the inside-class init
// (which uses the FIXED direct-store path) and the from-main
// reads via at() (which uses the FIXED subscript-load path).
// If any of those writes mis-routed to bank 0, the wipe would
// clobber them and the readback would fail.
//
// Also covered: chained `s.items[i].field = X` write and
// `s.items[i].field` read from outside the class, where `s` is a
// banked:Set@ pointer. The reader now stages s as a banked
// pointer and reads items[i]'s 3 bytes via _banked_load_byte
// from offset (ivarOff + i*3); the write side flows through the
// existing pointer-base banked-store path once the read returns
// A=lo / X=hi / Y=bank correctly.
//
// Dynamic-index variants are also covered:
//   - `items[i] = expr` from inside a method body (ivar-array
//     dyn-store branch in ExprAssign.m).
//   - `s.items[j].marker = X` and `s.items[j].marker` from
//     outside (dyn extension to ivarArrayOnBankedReceiverReadOrNo
//     in ExprMembers.m).
// Loop-driven init() (`while (i < 3) items[i] = new Slot();`)
// pins the inside-class store; the from-outside chained tests
// pick up the matching read path.

#import "Stdio.xc"
#import "Assert.xc"

class Slot { u16 marker; }
class Set {
    banked:Slot* items[3];

    void init(void) {
        // Loop-driven dynamic-index store. Pre-fix this fell to a
        // bogus `STA ($8001),Y` (xta interpreting the 0x8000-tagged
        // ivar address as a literal). Now goes through the
        // ivar-array dyn-store branch.
        u8 i = 0;
        while (i < 3) {
            items[i] = new Slot();
            i = i + 1;
        }
        return;
    }

    // Return items[i]. Uses the ivar-array subscript-LOAD branch
    // and the Y-preservation fix in emitFrameRestore.
    banked:Slot* at(u8 i)
    {
        if (i == 0) { return items[0]; }
        if (i == 1) { return items[1]; }
        return items[2];
    }
}

// Decoy: wipe bank 0 between writes and reads. Any write that
// mis-routed there gets clobbered.
void wipe_bank0(void)
{
    asm {
        LDA __bank_data_reg
        PHA
        LDA #$00
        STA __bank_data_reg
        LDA #$00
        LDX #$00
_wipe:
        STA $A000,X
        STA $A100,X
        STA $A200,X
        STA $A300,X
        STA $A400,X
        STA $A500,X
        STA $A600,X
        STA $A700,X
        STA $A800,X
        STA $A900,X
        STA $AA00,X
        STA $AB00,X
        STA $AC00,X
        STA $AD00,X
        STA $AE00,X
        STA $AF00,X
        STA $B000,X
        STA $B100,X
        STA $B200,X
        STA $B300,X
        STA $B400,X
        STA $B500,X
        STA $B600,X
        STA $B700,X
        STA $B800,X
        STA $B900,X
        STA $BA00,X
        STA $BB00,X
        STA $BC00,X
        STA $BD00,X
        STA $BE00,X
        STA $BF00,X
        STA $C000,X
        STA $C100,X
        STA $C200,X
        STA $C300,X
        STA $C400,X
        STA $C500,X
        STA $C600,X
        STA $C700,X
        STA $C800,X
        STA $C900,X
        STA $CA00,X
        STA $CB00,X
        STA $CC00,X
        STA $CD00,X
        STA $CE00,X
        STA $CF00,X
        INX
        BNE _wipe
        PLA
        STA __bank_data_reg
    }
    return;
}

void main(void)
{
    Assert.reset();
    u8* filler = new u8[4060];
    banked:Set* s = new Set();

    // Set markers via the chained banked-pointer method-call
    // return path. s.at(i) goes through the ivar-array
    // subscript-load fix; the resulting banked:Slot@ then
    // chains through the regular banked-pointer store path
    // which is well-tested (see heap_chain_method.xc).
    s.at(0).marker = $1111;
    s.at(1).marker = $2222;
    s.at(2).marker = $3333;

    // Wipe bank 0. Any pre-fix mis-route from at()'s ivar-array
    // load (returning a pointer with bank=0) would have caused
    // the marker writes above to land in bank 0. The wipe clears
    // them; the readbacks below would return $00 instead of the
    // planted markers.
    wipe_bank0();

    Assert.isEqual(s.at(0).marker, $1111);   // T1
    Assert.isEqual(s.at(1).marker, $2222);   // T2
    Assert.isEqual(s.at(2).marker, $3333);   // T3

    // Chained-from-outside shape: `s.items[i].marker = X` and the
    // matching read. ivarArrayOnBankedReceiverReadOrNo: stages s
    // as a banked pointer and reads items[i]'s 3 bytes through
    // _banked_load_byte. Each write below picks a distinct marker
    // so a mis-routed store would surface as a value mismatch.
    s.items[0].marker = $4444;
    s.items[1].marker = $5555;
    s.items[2].marker = $6666;

    wipe_bank0();

    Assert.isEqual(s.items[0].marker, $4444);   // T4
    Assert.isEqual(s.items[1].marker, $5555);   // T5
    Assert.isEqual(s.items[2].marker, $6666);   // T6

    // Dynamic-index chained-from-outside: `s.items[j].marker = X`
    // and matching read with j held in a u8 local. Each iteration
    // overwrites the previous markers so the assertions can only
    // pass if the dynamic-index codegen indexes correctly.
    u8 j = 0;
    while (j < 3) {
        s.items[j].marker = $7000 + (u16)j;
        j = j + 1;
    }
    wipe_bank0();
    j = 0;
    Assert.isEqual(s.items[j].marker, $7000);   // T7
    j = 1;
    Assert.isEqual(s.items[j].marker, $7001);   // T8
    j = 2;
    Assert.isEqual(s.items[j].marker, $7002);   // T9

    Assert.summary();
    return;
}
