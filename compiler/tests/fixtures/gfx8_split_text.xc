//xtc-flags: skip
// ^ The fixture is fundamentally Atari-specific: it asserts the
//   exact ANTIC display-list byte stream that `new Gfx8(n)` builds
//   for a split GR.8 + n-row GR.0 layout (LMS opcodes, mode-F
//   lines, JVB target = $8000), and reads SAVMSC ($58/$59) and
//   DINDEX ($57) via inline 6502 asm to confirm the OS-RAM writes
//   landed. arm64 has no ANTIC, no $58/$59/$57, and clang on arm64
//   rejects the 6502 mnemonics outright (the arm64 backend emits
//   inline asm verbatim). Skip until both backends have a
//   meaningful story for ANTIC display-list testing.
// gfx8_split_text.xc — `new Gfx8(n)` split GR.8 / n text rows.
// Verifies the DL byte stream + textBase computation + the
// SAVMSC / DINDEX writes that route Stdio.printf into the
// text rows. xts doesn't emulate ANTIC, so we can't observe
// the visible split — but we can confirm the DL bytes are
// laid out correctly, the JVB target was patched at $8000,
// and SAVMSC ($58/$59) was repointed at the text region.
//
// _buildSplitDL writes into the static scratch _gfx8_dlist; the
// init(textRows) caller copies that to $8000 (the 256-byte gap
// before the GR.8 screen RAM at $8100, always $400-aligned so
// ANTIC's DL fetcher never trips its 1 KB-wrap quirk). The
// static scratch is what we assert on here — its layout is
// fixed regardless of where the linker placed the array.
//
// Layout for n=4 (gr8Lines=160 = 96+64 split):
//   3x $70                 top BLANK
//   $4F $00 $81            LMS to graphics first half ($8100)
//   95x $0F                95 more mode F lines
//   $4F $00 $90            LMS to graphics second half ($9000)
//   63x $0F                63 more mode F lines (= 64 total)
//   $42 $00 $9A            LMS + mode 2 to text screen ($9A00)
//   3x $02                 3 more mode 2 lines (= 4 total)
//   $41 $00 $80            JVB to live DL at $8000
//
// Total DL bytes: 3 + 3 + 95 + 3 + 63 + 3 + 3 + 3 = 176

#import "Stdio.xc"
#import "Assert.xc"
#import "Gfx8.xc"

void main(void)
{
    Assert.reset();

    Gfx8* g = new Gfx8(4);

    // T1-T3: top BLANK margin.
    Assert.isEqual(_gfx8_dlist[0], $70);
    Assert.isEqual(_gfx8_dlist[1], $70);
    Assert.isEqual(_gfx8_dlist[2], $70);

    // T4-T6: first LMS to $8100.
    Assert.isEqual(_gfx8_dlist[3], $4F);
    Assert.isEqual(_gfx8_dlist[4], $00);
    Assert.isEqual(_gfx8_dlist[5], $81);

    // T7-T8: 95 more mode-F lines, then second LMS opcode.
    Assert.isEqual(_gfx8_dlist[100], $0F);
    Assert.isEqual(_gfx8_dlist[101], $4F);

    // T9-T10: second LMS to $9000.
    Assert.isEqual(_gfx8_dlist[102], $00);
    Assert.isEqual(_gfx8_dlist[103], $90);

    // T11: 63 more mode F lines = 64 second-half lines total.
    Assert.isEqual(_gfx8_dlist[166], $0F);

    // T12-T14: text section LMS at $9A00 (mode 2).
    Assert.isEqual(_gfx8_dlist[167], $42);
    Assert.isEqual(_gfx8_dlist[168], $00);
    Assert.isEqual(_gfx8_dlist[169], $9A);

    // T15-T16: 3 more mode 2 lines (= 4 total).
    Assert.isEqual(_gfx8_dlist[170], $02);
    Assert.isEqual(_gfx8_dlist[172], $02);

    // T17: JVB opcode at index 173.
    Assert.isEqual(_gfx8_dlist[173], $41);

    // T18-T19: JVB target = $8000 (the live DL location).
    Assert.isEqual(_gfx8_dlist[174], $00);
    Assert.isEqual(_gfx8_dlist[175], $80);

    // T20-T21: SAVMSC was set to $9A00 (textBase).
    u8 savmscLo;
    u8 savmscHi;
    asm
    {
        LDA $58
        STA savmscLo
        LDA $59
        STA savmscHi
    }
    Assert.isEqual(savmscLo, $00);
    Assert.isEqual(savmscHi, $9A);

    // T22: DINDEX = 0 (Stdio treats this as 40-col text mode).
    u8 dindex;
    asm
    {
        LDA $57
        STA dindex
    }
    Assert.isEqual(dindex, $00);

    // T23: clearBytes covers exactly the GR.8 region (160 lines
    // x 40 = 6400). The text RAM at sbase+6400 stays untouched
    // by clear() because the byte counter stops there.
    Assert.isEqual(g.clearBytes, 6400);

    Stdio.printf("DONE 23\n");
    return;
}
