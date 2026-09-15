// switch_stmt.xc — regression for the switch statement.
//
// Covers: u8 subject (single + multi-value cases, default, no default),
// u16 subject, enum subject, C-style fall-through, `break` exiting the
// switch, and a switch nested inside a loop where `break` only exits
// the switch (not the enclosing for). Tests T36..T52 drive the dense
// u8 dispatch through both the min==0 and SEC/SBC-bias code paths so
// the jump-table shape at -O2+ is exercised.
//
// xtc style: main() is tiny and just calls one function per group, so
// the bodies bank cleanly (a huge unbanked main() would overflow the
// $D800-$FFF9 budget). The companion inliner_ordering.xc fixture covers
// the inlined-helper case explicitly.

#import "Stdio.xc"

u8 testCount;
u8 failCount;
u8 fails[16];

void checkU8(u8 got, u8 want)
{
    testCount = testCount + 1;
    if (got != want) {
        if (failCount < 16) { fails[failCount] = testCount; }
        failCount = failCount + 1;
    }
}

enum Color = { red, green, blue, yellow = 10 };

// Globals so the switch subject is guaranteed to be read from memory
// (not constant-folded by the optimiser at compile time).
u8 gVal8;
u16 gVal16;
u8 gColor;
u8 gOut;
u8 gIter;
u8 gCount;

// ── T1..T6: u8 subject with multi-value arm and default ────────
void testU8Multi(void)
{
    gVal8 = 1;
    gOut = 0;
    switch (gVal8) {
        case 1:  gOut = $11; break;
        case 2:
        case 3:
        case 4:  gOut = $22; break;
        case 5:  gOut = $33; break;
        default: gOut = $FF; break;
    }
    checkU8(gOut, $11);

    gVal8 = 5;
    gOut = 0;
    switch (gVal8) {
        case 1:  gOut = $11; break;
        case 2:
        case 3:
        case 4:  gOut = $22; break;
        case 5:  gOut = $33; break;
        default: gOut = $FF; break;
    }
    checkU8(gOut, $33);

    gVal8 = 3;     // matches the multi-value arm (2/3/4 → $22)
    gOut = 0;
    switch (gVal8) {
        case 1:  gOut = $11; break;
        case 2:
        case 3:
        case 4:  gOut = $22; break;
        case 5:  gOut = $33; break;
        default: gOut = $FF; break;
    }
    checkU8(gOut, $22);

    gVal8 = 2;     // also the multi-value arm
    gOut = 0;
    switch (gVal8) {
        case 2:
        case 3:
        case 4:  gOut = $22; break;
        default: gOut = $FF; break;
    }
    checkU8(gOut, $22);

    gVal8 = 4;
    gOut = 0;
    switch (gVal8) {
        case 2:
        case 3:
        case 4:  gOut = $22; break;
        default: gOut = $FF; break;
    }
    checkU8(gOut, $22);

    gVal8 = 99;    // default
    gOut = 0;
    switch (gVal8) {
        case 1:  gOut = $11; break;
        default: gOut = $FF; break;
    }
    checkU8(gOut, $FF);
}

// ── T7..T10: C-style fall-through ──────────────────────────────
void testFallThrough(void)
{
    gVal8 = 1;
    gOut = 0;
    switch (gVal8) {
        case 1: gOut = gOut + $01;            // fall through
        case 2: gOut = gOut + $02; break;
        case 3: gOut = gOut + $04; break;
        default: gOut = gOut + $80; break;
    }
    checkU8(gOut, $03);                      // $01 + $02

    gVal8 = 2;
    gOut = 0;
    switch (gVal8) {
        case 1: gOut = gOut + $01;
        case 2: gOut = gOut + $02; break;
        case 3: gOut = gOut + $04; break;
        default: gOut = gOut + $80; break;
    }
    checkU8(gOut, $02);                      // starts at 2

    gVal8 = 3;
    gOut = 0;
    switch (gVal8) {
        case 1: gOut = gOut + $01;
        case 2: gOut = gOut + $02; break;
        case 3: gOut = gOut + $04; break;
        default: gOut = gOut + $80; break;
    }
    checkU8(gOut, $04);

    gVal8 = 9;
    gOut = 0;
    switch (gVal8) {
        case 1: gOut = gOut + $01;
        case 2: gOut = gOut + $02; break;
        case 3: gOut = gOut + $04; break;
        default: gOut = gOut + $80; break;
    }
    checkU8(gOut, $80);
}

// ── T11..T14: u16 subject, no default ──────────────────────────
void testU16(void)
{
    gVal16 = $0100;
    gOut = 0;
    switch (gVal16) {
        case $0100: gOut = $11; break;
        case $0200: gOut = $22; break;
        case $FFFF: gOut = $33; break;
    }
    checkU8(gOut, $11);

    gVal16 = $0200;
    gOut = 0;
    switch (gVal16) {
        case $0100: gOut = $11; break;
        case $0200: gOut = $22; break;
        case $FFFF: gOut = $33; break;
    }
    checkU8(gOut, $22);

    gVal16 = $FFFF;
    gOut = 0;
    switch (gVal16) {
        case $0100: gOut = $11; break;
        case $0200: gOut = $22; break;
        case $FFFF: gOut = $33; break;
    }
    checkU8(gOut, $33);

    gVal16 = $1234;     // no match, no default → gOut stays 0
    gOut = 0;
    switch (gVal16) {
        case $0100: gOut = $11; break;
        case $0200: gOut = $22; break;
        case $FFFF: gOut = $33; break;
    }
    checkU8(gOut, $00);
}

// ── T15..T19: enum subject ─────────────────────────────────────
void testEnum(void)
{
    gColor = red;
    gOut = 0;
    switch (gColor) {
        case red:    gOut = 1;  break;
        case green:  gOut = 2;  break;
        case blue:   gOut = 3;  break;
        case yellow: gOut = 10; break;
        default:     gOut = $FF; break;
    }
    checkU8(gOut, 1);

    gColor = green;  gOut = 0;
    switch (gColor) {
        case red:    gOut = 1;  break;
        case green:  gOut = 2;  break;
        case blue:   gOut = 3;  break;
        case yellow: gOut = 10; break;
        default:     gOut = $FF; break;
    }
    checkU8(gOut, 2);

    gColor = blue;  gOut = 0;
    switch (gColor) {
        case red:    gOut = 1;  break;
        case green:  gOut = 2;  break;
        case blue:   gOut = 3;  break;
        case yellow: gOut = 10; break;
        default:     gOut = $FF; break;
    }
    checkU8(gOut, 3);

    gColor = yellow;  gOut = 0;
    switch (gColor) {
        case red:    gOut = 1;  break;
        case green:  gOut = 2;  break;
        case blue:   gOut = 3;  break;
        case yellow: gOut = 10; break;
        default:     gOut = $FF; break;
    }
    checkU8(gOut, 10);

    gColor = 99;  gOut = 0;
    switch (gColor) {
        case red:    gOut = 1;  break;
        default:     gOut = $FF; break;
    }
    checkU8(gOut, $FF);
}

// ── T20: switch's break inside a for loop must NOT exit the loop.
// 0→$01, 1→$02, 2→$04, 3→$10, 4→$10 → $27
void testBreakInLoop(void)
{
    gCount = 0;
    for (gIter = 0; gIter < 5; gIter = gIter + 1) {
        switch (gIter) {
            case 0: gCount = gCount + $01; break;
            case 1: gCount = gCount + $02; break;
            case 2: gCount = gCount + $04; break;
            default: gCount = gCount + $10; break;
        }
    }
    checkU8(gCount, $27);
}

// ── T21..T24: bounded range `case 5..9:` — matches 5,6,7,8,9 ──
void testBoundedRange(void)
{
    gVal8 = 5;   gOut = 0;
    switch (gVal8) {
        case 5..9: gOut = $AA; break;
        default:   gOut = $00; break;
    }
    checkU8(gOut, $AA);

    gVal8 = 7;   gOut = 0;
    switch (gVal8) {
        case 5..9: gOut = $AA; break;
        default:   gOut = $00; break;
    }
    checkU8(gOut, $AA);

    gVal8 = 9;   gOut = 0;
    switch (gVal8) {
        case 5..9: gOut = $AA; break;
        default:   gOut = $00; break;
    }
    checkU8(gOut, $AA);

    gVal8 = 4;   gOut = 0;   // just below
    switch (gVal8) {
        case 5..9: gOut = $AA; break;
        default:   gOut = $00; break;
    }
    checkU8(gOut, $00);
}

// ── T25..T27: unbounded-low `case ..5:` — matches v <= 5 ──
void testUnboundedLow(void)
{
    gVal8 = 0;   gOut = 0;
    switch (gVal8) {
        case ..5: gOut = $55; break;
        default:  gOut = $00; break;
    }
    checkU8(gOut, $55);

    gVal8 = 5;   gOut = 0;
    switch (gVal8) {
        case ..5: gOut = $55; break;
        default:  gOut = $00; break;
    }
    checkU8(gOut, $55);

    gVal8 = 6;   gOut = 0;
    switch (gVal8) {
        case ..5: gOut = $55; break;
        default:  gOut = $00; break;
    }
    checkU8(gOut, $00);
}

// ── T28..T30: unbounded-high `case 12..:` — matches v >= 12 ──
void testUnboundedHigh(void)
{
    gVal8 = 12;  gOut = 0;
    switch (gVal8) {
        case 12..: gOut = $CC; break;
        default:   gOut = $00; break;
    }
    checkU8(gOut, $CC);

    gVal8 = 200; gOut = 0;
    switch (gVal8) {
        case 12..: gOut = $CC; break;
        default:   gOut = $00; break;
    }
    checkU8(gOut, $CC);

    gVal8 = 11;  gOut = 0;
    switch (gVal8) {
        case 12..: gOut = $CC; break;
        default:   gOut = $00; break;
    }
    checkU8(gOut, $00);
}

// ── T31..T34: mixed single + range in the same switch ──
// 0 → single $A0; 1..3 → range $A1; 10..20 → range $A2;
// 255 → single $A3; anything else → default $00.
void testMixedRange(void)
{
    for (u8 j = 0; j < 4; j = j + 1) {
        u8 pv;
        u8 want;
        if (j == 0)      { pv = 0;    want = $A0; }
        else if (j == 1) { pv = 2;    want = $A1; }
        else if (j == 2) { pv = 15;   want = $A2; }
        else             { pv = 255;  want = $A3; }
        gVal8 = pv; gOut = 0;
        switch (gVal8) {
            case 0:     gOut = $A0; break;
            case 1..3:  gOut = $A1; break;
            case 10..20: gOut = $A2; break;
            case 255:   gOut = $A3; break;
            default:    gOut = $00; break;
        }
        checkU8(gOut, want);
    }
}

// ── T35: range on enum subject ──
void testEnumRange(void)
{
    gColor = green;   // = 1
    gOut = 0;
    switch (gColor) {
        case red..blue: gOut = $11; break;    // red=0, green=1, blue=2 (inclusive)
        case yellow:    gOut = $22; break;
        default:        gOut = $FF; break;
    }
    checkU8(gOut, $11);
}

// ── T36..T43: dense 6-way switch that should dispatch via a jump
// table at -O2+. Same arm bodies as T1-style but done across every
// possible input so we hit each table entry and the default twice.
// Behaviour must match the chained form at -O0.
void testJumpTable(void)
{
    for (gIter = 0; gIter < 8; gIter = gIter + 1) {
        u8 want;
        switch (gIter) {
            case 0: want = $01; break;
            case 1: want = $02; break;
            case 2: want = $04; break;
            case 3: want = $08; break;
            case 4: want = $10; break;
            case 5: want = $20; break;
            default: want = $FF; break;
        }
        gVal8 = gIter;
        gOut = 0;
        switch (gVal8) {
            case 0: gOut = $01; break;
            case 1: gOut = $02; break;
            case 2: gOut = $04; break;
            case 3: gOut = $08; break;
            case 4: gOut = $10; break;
            case 5: gOut = $20; break;
            default: gOut = $FF; break;
        }
        checkU8(gOut, want);
    }
}

// ── T44..T49: same shape but non-zero min (cases 10..14) — tests
// the SEC/SBC-bias path in the table dispatch.
void testJumpTableBias(void)
{
    for (gIter = 8; gIter < 17; gIter = gIter + 1) {
        u8 want;
        switch (gIter) {
            case 10: want = $0A; break;
            case 11: want = $0B; break;
            case 12: want = $0C; break;
            case 13: want = $0D; break;
            case 14: want = $0E; break;
            default: want = $FF; break;
        }
        gVal8 = gIter;
        gOut = 0;
        switch (gVal8) {
            case 10: gOut = $0A; break;
            case 11: gOut = $0B; break;
            case 12: gOut = $0C; break;
            case 13: gOut = $0D; break;
            case 14: gOut = $0E; break;
            default: gOut = $FF; break;
        }
        checkU8(gOut, want);
    }
}

void main(void)
{
    testCount = 0;
    failCount = 0;

    testU8Multi();
    testFallThrough();
    testU16();
    testEnum();
    testBreakInLoop();
    testBoundedRange();
    testUnboundedLow();
    testUnboundedHigh();
    testMixedRange();
    testEnumRange();
    testJumpTable();
    testJumpTableBias();

    u8 i;
    for (i = 0; i < failCount; i = i + 1) {
        if (i < 16) { Stdio.printf("T%u FAIL\n", fails[i]); }
    }
    Stdio.printf("DONE %u\n", testCount);
}
