// subscript_u16_read.xc — `buf[i]` with u16 index ≥ 256.
//
// Pre-fix, the legacy fallthrough in emitSubscriptExpr emitted
// `LDA idx_lo / TAY / LDA (ptr),Y`, dropping the index's high
// byte and reading `buf[i & $FF]` instead of `buf[i]`. The
// matching WRITE path was already correct (CLC/ADC both halves
// of the index into a staged pointer), so the round-trip
// `buf[i] = v; v == buf[i]` masked the bug for any single-test
// fixture that wrote and read at the same wide index.
//
// This fixture decouples writes from reads:
//   - Write distinct sentinels at offsets 24, 280, 4000.
//   - Read each through both literal and variable u16 indices.
// If the truncation bug returns, buf[280] reads buf[24]'s
// sentinel and the test fails immediately.

#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    u8* buf = new u8[7680];
    u16 i = 0;
    while (i < 7680) {
        buf[i] = 0;
        i = i + 1;
    }

    buf[24]   = $24;
    buf[280]  = $80;     // 280 mod 256 = 24 — overlaps with $24 if truncated
    buf[4000] = $A0;     // 4000 mod 256 = 160

    // Literal u16 index reads.
    Assert.isEqual(buf[24],   $24);
    Assert.isEqual(buf[280],  $80);
    Assert.isEqual(buf[4000], $A0);

    // Variable u16 index reads (cross-checks the same path
    // through emitExprToA evaluating a ZP-resident index).
    u16 a = 24;
    u16 b = 280;
    u16 c = 4000;
    Assert.isEqual(buf[a], $24);
    Assert.isEqual(buf[b], $80);
    Assert.isEqual(buf[c], $A0);

    Assert.summary();
    return;
}
