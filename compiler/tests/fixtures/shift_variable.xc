#import "Stdio.xc"
#import "Assert.xc"

void main(void) {
    Assert.reset();

    // ── Variable-count right shift: $80 >> bit ────────────────────
    u8 x = $80;
    u8 bit;
    u8 r;

    bit = 0;  r = x >> bit;  Assert.isEqual((u16)r, $80);  // T1
    bit = 1;  r = x >> bit;  Assert.isEqual((u16)r, $40);  // T2
    bit = 2;  r = x >> bit;  Assert.isEqual((u16)r, $20);  // T3
    bit = 3;  r = x >> bit;  Assert.isEqual((u16)r, $10);  // T4
    bit = 4;  r = x >> bit;  Assert.isEqual((u16)r, $08);  // T5
    bit = 5;  r = x >> bit;  Assert.isEqual((u16)r, $04);  // T6
    bit = 6;  r = x >> bit;  Assert.isEqual((u16)r, $02);  // T7
    bit = 7;  r = x >> bit;  Assert.isEqual((u16)r, $01);  // T8

    // ── Variable-count left shift: 1 << bit ───────────────────────
    u16 result16;
    bit = 0;  result16 = (u16)(1 << bit);  Assert.isEqual(result16, 1);    // T9
    bit = 1;  result16 = (u16)(1 << bit);  Assert.isEqual(result16, 2);    // T10
    bit = 2;  result16 = (u16)(1 << bit);  Assert.isEqual(result16, 4);    // T11
    bit = 3;  result16 = (u16)(1 << bit);  Assert.isEqual(result16, 8);    // T12
    bit = 4;  result16 = (u16)(1 << bit);  Assert.isEqual(result16, 16);   // T13
    bit = 5;  result16 = (u16)(1 << bit);  Assert.isEqual(result16, 32);   // T14
    bit = 6;  result16 = (u16)(1 << bit);  Assert.isEqual(result16, 64);   // T15
    bit = 7;  result16 = (u16)(1 << bit);  Assert.isEqual(result16, 128);  // T16

    // ── Constant << variable ─────────────────────────────────────
    u8 c = 3;
    bit = 4;
    result16 = (u16)(c << bit);
    Assert.isEqual(result16, 48);             // T17: 3 << 4 = 48

    // ── Literal shift (constant path still works) ─────────────────
    r = x >> 1;  Assert.isEqual((u16)r, $40);   // T18
    r = x >> 3;  Assert.isEqual((u16)r, $10);   // T19
    r = x >> 7;  Assert.isEqual((u16)r, $01);   // T20
    r = x << 0;  Assert.isEqual((u16)r, $80);   // T21: shift by 0 is no-op
    r = x << 1;  Assert.isEqual((u16)r, $00);   // T22: $80 << 1 = $100 → $00

    // ── 16-bit shift with variable count ──────────────────────────
    u16 wide = $0080;
    bit = 1;  Assert.isEqual(wide << bit, $0100);  // T23
    bit = 2;  Assert.isEqual(wide >> bit, $0020);  // T24

    // ── Signed i8 right shift (arithmetic) ────────────────────────
    i8 s = (i8)$F0;   // -16
    i16 sr;

    bit = 0;  sr = s >> bit;  Assert.isEqual(sr, (i16)-16);  // T25
    bit = 1;  sr = s >> bit;  Assert.isEqual(sr, (i16)(-8)); // T26
    bit = 2;  sr = s >> bit;  Assert.isEqual(sr, (i16)(-4)); // T27
    bit = 3;  sr = s >> bit;  Assert.isEqual(sr, (i16)(-2)); // T28
    bit = 4;  sr = s >> bit;  Assert.isEqual(sr, (i16)(-1)); // T29

    Stdio.printf("DONE 29\n");
}
