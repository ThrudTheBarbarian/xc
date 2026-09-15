//xtc-na: arm64,arm9,x86_64,win64 — dereferences the 6502 zero-page ($0000) sentinel
// array_direct_zp.xc — G1: stack-array subscripts use direct ZP
// addressing instead of dereferencing the base slot as a pointer.
//
// Before G1 the codegen treated every non-spilled subscript base as
// a pointer: `LDA $baseZP / STA zpTmp / LDA $(baseZP+1) / STA zpTmp+1`
// then `(zpTmp),Y`. For an XTArrayType whose ZP slot IS the array's
// first two bytes, that indirection read bytes 0/1 of the array as
// the "pointer" and indexed through it. On xts (zero-filled ZP) this
// worked by coincidence because the resulting address landed at
// $0000 + offset and the test's writes happened to go through the
// same broken pointer. On real hardware (non-zero OS zero-page bytes
// at $0000-$7F) reads and writes would corrupt OS state.
//
// Post-G1: XTArrayType bases use absolute addressing (constant index)
// or stage baseZP as an immediate into zpTmp (dynamic index) and then
// use `(zpTmp),Y` correctly. This fixture exercises u8/u16/u32 stack
// arrays with both constant and dynamic indices.

#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    // ── u16 stack array, const + dynamic indices ──
    u16 buf16[8];
    buf16[0] = $1234;
    buf16[1] = $5678;
    buf16[7] = $DEAD;

    u16 i = 3;
    buf16[i] = $BEEF;

    Assert.isEqual(buf16[0], $1234);                 // T1 const read
    Assert.isEqual(buf16[1], $5678);                 // T2
    Assert.isEqual(buf16[7], $DEAD);                 // T3 high-index const
    Assert.isEqual(buf16[i], $BEEF);                 // T4 dyn read

    // ── u32 stack array, const + dynamic indices ──
    u32 buf32[4];
    buf32[0] = $12345678;
    buf32[3] = $DEADBEEF;

    u8 j = 1;
    buf32[j] = $CAFEBABE;

    if (buf32[0] == $12345678) { Assert.isTrue(true); } else { Assert.isTrue(false); }   // T5
    if (buf32[3] == $DEADBEEF) { Assert.isTrue(true); } else { Assert.isTrue(false); }   // T6
    if (buf32[j] == $CAFEBABE) { Assert.isTrue(true); } else { Assert.isTrue(false); }   // T7

    // ── u8 stack array, dyn index (const u8 uses the legacy path) ──
    u8 buf8[6];
    buf8[0] = $AA;
    buf8[5] = $55;
    u8 k = 2;
    buf8[k] = $C3;

    Assert.isTrue(buf8[0] == $AA);                   // T8
    Assert.isTrue(buf8[5] == $55);                   // T9
    Assert.isTrue(buf8[k] == $C3);                   // T10

    // ── Sanity: arrays don't trample OS zero-page ──
    // On real hardware $00-$7F is critical OS memory. Post-G1 our
    // writes land at the actual array base (typically $80-$FF), so
    // OS bytes are untouched. Under the pre-G1 indirection-through-
    // zero bug, every write above would have stomped on $0000+off,
    // clobbering OSVARS. This assert is a sentinel: if we detect a
    // write landed at $0000, it's a regression.
    u8* osVec = (u8*)0;
    Assert.isEqual(*osVec, 0);                       // T11 sentinel

    Assert.summary();
    return;
}
