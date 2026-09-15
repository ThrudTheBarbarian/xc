// foundation_data.xc — Data.xc smoke + correctness tests.
//
//   T1   withBytes copies a u8[N] source into a fresh allocation.
//   T2   byteAt round-trips each input byte.
//   T3   withLength returns a zero-filled buffer of the given size, and
//        withCapacity RESERVES without producing bytes.
//   T4   setByteAt mutates the buffer.
//   T5   equals — same bytes, same length.
//   T6   equals — same length, different bytes.
//   T7   equals — different lengths.
//
// Heap-capable targets only.

#import "Stdio.xc"
#import "Data.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    u8 raw[4] = { $DE, $AD, $BE, $EF };
    Data* d = Data.withBytes(&raw[0], (u16)4);
    Assert.isEqual(d.length(), (u16)4);                          // T1

    // byteAt returns u8 — route through locals before the (u16) cast.
    u8 b0 = d.byteAt((u16)0);  Assert.isEqual((u16)b0, (u16)$DE); // T2a
    u8 b1 = d.byteAt((u16)1);  Assert.isEqual((u16)b1, (u16)$AD); // T2b
    u8 b3 = d.byteAt((u16)3);  Assert.isEqual((u16)b3, (u16)$EF); // T2c

    Data* z = Data.withLength((u16)3);
    Assert.isEqual(z.length(), (u16)3);                          // T3a
    u8 zb = z.byteAt((u16)1);
    Assert.isEqual((u16)zb, (u16)0);                             // T3b — zero-init

    // withCapacity is a RESERVATION: it yields no bytes, and appending on top
    // of it fills from the front rather than doubling the buffer.
    Data* r = Data.withCapacity((u16)8);
    Assert.isEqual(r.length(), (u16)0);                          // T3c
    r.appendByte((u8)$DE);
    r.appendByte((u8)$AD);
    Assert.isEqual(r.length(), (u16)2);                          // T3d
    u8 r0 = r.byteAt((u16)0);
    Assert.isEqual((u16)r0, (u16)$DE);                           // T3e

    z.setByteAt((u16)0, (u8)11);
    z.setByteAt((u16)1, (u8)22);
    z.setByteAt((u16)2, (u8)33);
    u8 zb2 = z.byteAt((u16)1);
    Assert.isEqual((u16)zb2, (u16)22);                           // T4

    Data* e = Data.withBytes(&raw[0], (u16)4);
    Assert.isTrue(d.equals(e));                                  // T5

    u8 raw2[4] = { $DE, $AD, $BE, $00 };                         // last byte differs
    Data* f = Data.withBytes(&raw2[0], (u16)4);
    Assert.isTrue(!d.equals(f));                                 // T6

    Data* g = Data.withBytes(&raw[0], (u16)2);                   // shorter
    Assert.isTrue(!d.equals(g));                                 // T7

    Assert.summary();
    return;
}
