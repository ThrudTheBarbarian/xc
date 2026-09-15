//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
// stdio_scroll.xc — Stdio.printf scrolls the text region when
// output overflows the bottom row. Pre-fix, putChar walked
// screenPtr forward indefinitely and would write past the end
// of the text region — fine for full GR.0 (the OS reset SAVMSC
// each VBI) but catastrophic for setupSplit's 4-row text
// strip, which would smear into adjacent heap.
//
// Test setup: drop BOTSCR ($02BF) to 3 (3 rows of text), then
// fill the region with a recognisable per-row character. After
// the third row prints, the next character should trigger
// scroll() — row 0 disappears, row 1 becomes row 0, row 2
// becomes row 1, and the new character lands in row 2.
//
//   T1   row 0 originally 'A...' -> after scroll, row 0 is 'B'
//   T2   row 1 after scroll holds the prior row 2 ('C')
//   T3   row 2 after scroll starts with the NEW character ('D')
//   T4   the rest of the new row 2 stays cleared (screen-code 0)

#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    // Force a 3-row text region. Stdio's lazy-init reads BOTSCR
    // on its first putChar so we need to set it BEFORE the
    // first Stdio call (Assert.reset is the first such call,
    // so set BOTSCR before that).
    asm
    {
        LDA #$03
        STA $02BF
    }
    Assert.reset();

    // Each printf writes 40 chars (one row's worth) — putting
    // a fresh letter in each row.
    Stdio.printf("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    Stdio.printf("BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
    Stdio.printf("CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC");
    // The next char triggers scroll: A row falls off the top,
    // 'D' lands in row 2 col 0.
    Stdio.printf("D");

    // Read SAVMSC so the asserts below can index the text region
    // without assuming a specific address.
    u16 sb;
    asm
    {
        LDA $58
        STA sb
        LDA $59
        STA sb+1
    }
    u8* scr = (u8*)sb;

    // Internal screen codes: 'A' = $21, 'B' = $22, 'C' = $23,
    // 'D' = $24 (ASCII - $20).
    Assert.isEqual(scr[0],   $22);    // row 0 col 0 = 'B'
    Assert.isEqual(scr[40],  $23);    // row 1 col 0 = 'C'
    Assert.isEqual(scr[80],  $24);    // row 2 col 0 = 'D' (just printed)
    Assert.isEqual(scr[81],  $00);    // row 2 col 1 still cleared

    Stdio.printf("\nDONE 4\n");
    return;
}