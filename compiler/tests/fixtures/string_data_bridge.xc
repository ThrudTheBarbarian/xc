// string_data_bridge.xc — text ↔ bytes.
//
// self-hosting M2. M1 listed the byte/encoding bridge (dataUsingEncoding:,
// initWithData:, initWithBytes:, getBytes:, lengthOfBytesUsingEncoding:) as
// "mostly thin over the existing _bytes buffer" — it is, but the thin parts are
// where the off-by-one lives.
//
// Both conversion directions are METHODS ON DATA (Data.withString /
// stringValue) rather than half on each class: Data already imports String, and
// the reverse import would make the two files depend on each other.
//
//   T1  Data.withString — the bytes WITHOUT the trailing NUL
//   T2  Data.stringValue — round-trip, and the embedded-NUL case where
//       length() stays right but cString() stops early
//   T3  String.getBytes — the copied count, a destination smaller than the
//       string, and no NUL written past what was asked for
//   T4  byteLength
//   T5  increaseLengthBy / setLength — zero-filled growth, truncation

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void t1_t2(void)
{
    // ── T1: to bytes. "abc" is THREE bytes as a Data, not four — a blob
    // carries its length and does not need a terminator.
    String* s = String.withCString("abc");
    Data* d = Data.withString(s);
    Assert.isEqual((u16)d.length(), (u16)3);                       // T1a
    Assert.isEqual((u16)d.byteAt((u16)0), (u16)'a');               // T1b
    Assert.isEqual((u16)d.byteAt((u16)2), (u16)'c');

    Assert.isEqual((u16)Data.withString(String.withCString("")).length(), (u16)0);  // T1c
    Assert.isEqual((u16)Data.withString((String*)0).length(), (u16)0);              // T1d

    // ── T2: back again.
    Assert.isTrue(d.stringValue().equals(s));                      // T2a
    Assert.isEqual((u16)d.stringValue().byteLength(), (u16)3);

    // A blob with an embedded NUL becomes a String of the right LENGTH; only
    // the C view of it stops early, which is C's limit and not the bridge's.
    u8 raw[5];
    raw[0] = (u8)'a'; raw[1] = (u8)0; raw[2] = (u8)'b';
    raw[3] = (u8)0;   raw[4] = (u8)'c';
    Data* holey = Data.withBytes(&raw[0], (u16)5);
    String* text = holey.stringValue();
    Assert.isEqual((u16)text.byteLength(), (u16)5);                    // T2b
    Assert.isEqual((u16)text.byteAt((u16)2), (u16)'b');            // T2c — past the NUL
    Assert.isEqual((u16)String._cstringLen(text.cString()), (u16)1);// T2d — C sees one

    // Round-trip preserves every byte.
    Assert.isTrue(Data.withString(text).equals(holey));            // T2e
}

void t3_t4(void)
{
    String* s = String.withCString("hello");

    // ── T3: getBytes copies as much as it is given room for, and says how
    // much that was.
    u8 buf[8];
    for (u16 i = (u16)0; i < (u16)8; i = i + (u16)1) buf[i] = (u8)$DE;

    u16 n = (u16)s.getBytes(&buf[0], (u16)8);
    Assert.isEqual(n, (u16)5);                                     // T3a
    Assert.isEqual((u16)buf[0], (u16)'h');                         // T3b
    Assert.isEqual((u16)buf[4], (u16)'o');
    // NOTHING is written past the copied bytes — no NUL, no padding. The
    // sentinel is still there.
    Assert.isEqual((u16)buf[5], (u16)$DE);                         // T3c

    // A destination smaller than the string truncates rather than overruns.
    for (u16 i = (u16)0; i < (u16)8; i = i + (u16)1) buf[i] = (u8)$DE;
    n = (u16)s.getBytes(&buf[0], (u16)3);
    Assert.isEqual(n, (u16)3);                                     // T3d
    Assert.isEqual((u16)buf[2], (u16)'l');
    Assert.isEqual((u16)buf[3], (u16)$DE);                         // T3e — untouched

    // Zero room copies nothing; a null destination is not a crash.
    n = (u16)s.getBytes(&buf[0], (u16)0);
    Assert.isEqual(n, (u16)0);                                     // T3f
    n = (u16)s.getBytes((u8*)0, (u16)4);
    Assert.isEqual(n, (u16)0);                                     // T3g

    // ── T4.
    Assert.isEqual((u16)s.byteLength(), (u16)5);                   // T4a
    Assert.isEqual((u16)String.withCString("").byteLength(), (u16)0);  // T4b
}

void t5(void)
{
    // ── T5: increaseLengthBy / setLength.
    u8 raw[2];
    raw[0] = (u8)$AA; raw[1] = (u8)$BB;
    Data* d = Data.withBytes(&raw[0], (u16)2);

    d.increaseLengthBy((u16)3);
    Assert.isEqual((u16)d.length(), (u16)5);                       // T5a
    Assert.isEqual((u16)d.byteAt((u16)1), (u16)$BB);               // T5b — kept
    // The new bytes are ZEROED, not whatever the allocator had.
    Assert.isEqual((u16)d.byteAt((u16)2), (u16)0);                 // T5c
    Assert.isEqual((u16)d.byteAt((u16)4), (u16)0);

    d.increaseLengthBy((u16)0);
    Assert.isEqual((u16)d.length(), (u16)5);                       // T5d

    d.setLength((u16)2);
    Assert.isEqual((u16)d.length(), (u16)2);                       // T5e
    Assert.isEqual((u16)d.byteAt((u16)0), (u16)$AA);

    d.setLength((u16)4);
    Assert.isEqual((u16)d.length(), (u16)4);                       // T5f
    Assert.isEqual((u16)d.byteAt((u16)3), (u16)0);                 // T5g — zero-filled
}

void main(void)
{
    t1_t2();
    t3_t4();
    t5();
    Assert.summary();
    return;
}
