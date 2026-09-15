// foundation_string_api.xc — String is a real string class now.
//
// It used to be length / charAt / cString / equals / hash, and nothing else.
// You could not find a substring, take one, join two, trim one, or split one.
// Every program that touched text had to reach back into raw `u8@` and do it by
// hand, which is exactly what a Foundation is supposed to spare you.
//
// It also leaked: `_bytes` is a raw `u8@`, which the automatic aggregate walker
// does not reclaim, and String had no dealloc. 300,000 Strings leaked 90 MB.
//
//   T1  building: withCString / withString / withBytes / isEmpty
//   T2  searching: indexOfChar / lastIndexOfChar / indexOf / contains
//   T3  prefix / suffix
//   T4  slicing: substring / substringFrom / substringTo, and out-of-range
//       clamping to empty rather than faulting
//   T5  mutation: append / appendChar / appendCString, and `appending` leaving
//       the receiver alone
//   T6  case: uppercased / lowercased / caseInsensitiveCompare
//   T7  trimmed
//   T8  split — including the empty components that a CSV needs
//   T9  join
//   T10 replacing
//   T11 ordering: lexicographic, prefix before extension

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void t1_t2(void)
{
    // ── T1: building.
    String* s = String.withCString("hello");
    Assert.isEqual(s.byteLength(), (u16)5);                            // T1a
    Assert.isFalse(s.isEmpty());
    Assert.isTrue(String.withCString("").isEmpty());               // T1b

    String* copy = String.withString(s);
    Assert.isTrue(copy.equals(s));                                 // T1c
    Assert.isEqual(copy.byteLength(), (u16)5);

    u8 raw[4];
    raw[0] = (u8)'a'; raw[1] = (u8)'b'; raw[2] = (u8)'c'; raw[3] = (u8)'d';
    String* fromBytes = String.withBytes(&raw[0], (u16)3);         // no NUL needed
    Assert.isEqual(fromBytes.byteLength(), (u16)3);                    // T1d
    Assert.isTrue(fromBytes.equals(String.withCString("abc")));

    // ── T2: searching.
    String* h = String.withCString("hello world");
    Assert.isEqual(h.indexOfByte((u8)'o'),     (u16)4);            // T2a — first
    Assert.isEqual(h.lastIndexOfByte((u8)'o'), (u16)7);            // T2b — last
    Assert.isEqual(h.indexOfByte((u8)'z'), String.notFound());     // T2c

    Assert.isEqual(h.byteIndexOf(String.withCString("world")), (u16)6);// T2d
    Assert.isEqual(h.byteIndexOf(String.withCString("nope")), String.notFound());
    Assert.isTrue(h.contains(String.withCString("lo w")));         // T2e
    Assert.isFalse(h.contains(String.withCString("W")));           // case matters
}

void t3_t4(void)
{
    String* h = String.withCString("hello world");

    // ── T3.
    Assert.isTrue(h.hasPrefix(String.withCString("hello")));       // T3a
    Assert.isFalse(h.hasPrefix(String.withCString("world")));
    Assert.isTrue(h.hasSuffix(String.withCString("world")));       // T3b
    Assert.isFalse(h.hasSuffix(String.withCString("hello")));

    // ── T4: slicing, and clamping.
    Assert.isTrue(h.substringBytes((u16)6, (u16)5).equals(String.withCString("world")));   // T4a
    Assert.isTrue(h.substringFromByte((u16)6).equals(String.withCString("world")));       // T4b
    Assert.isTrue(h.substringToByte((u16)5).equals(String.withCString("hello")));         // T4c

    // Past the end is an empty String, not a fault and not garbage.
    Assert.isTrue(h.substringFromByte((u16)99).isEmpty());                                // T4d
    // A length past the end clamps.
    Assert.isTrue(h.substringBytes((u16)6, (u16)999).equals(String.withCString("world"))); // T4e
}

void t5_t6_t7(void)
{
    // ── T5: mutation, and the non-mutating twin.
    String* acc = String.withCString("ab");
    acc.append(String.withCString("cd"));
    acc.appendByte((u8)'!');
    acc.appendCString("?");
    Assert.isTrue(acc.equals(String.withCString("abcd!?")));       // T5a
    Assert.isEqual(acc.byteLength(), (u16)6);

    String* base = String.withCString("x");
    String* more = base.appending(String.withCString("y"));
    Assert.isTrue(more.equals(String.withCString("xy")));          // T5b
    Assert.isTrue(base.equals(String.withCString("x")));           // T5c — untouched

    // ── T6: case.
    String* mixed = String.withCString("HeLLo");
    Assert.isTrue(mixed.uppercased().equals(String.withCString("HELLO")));  // T6a
    Assert.isTrue(mixed.lowercased().equals(String.withCString("hello")));  // T6b
    Assert.isTrue(mixed.equals(String.withCString("HeLLo")));               // T6c — untouched
    Assert.isEqual((i16)String.withCString("ABC").caseInsensitiveCompare(String.withCString("abc")), (i16)0);
    Assert.isTrue(String.withCString("ABC").equalsIgnoringCase(String.withCString("abc")));  // T6d
    Assert.isFalse(String.withCString("ABC").equals(String.withCString("abc")));             // …but not equal

    // ── T7: trimmed.
    Assert.isTrue(String.withCString("  hi  ").trimmed().equals(String.withCString("hi")));  // T7a
    Assert.isTrue(String.withCString("hi").trimmed().equals(String.withCString("hi")));      // T7b
    Assert.isTrue(String.withCString("   ").trimmed().isEmpty());                            // T7c
}

void t8_t9_t10_t11(void)
{
    // ── T8: split. Empty components are REAL components — "a,,b" is three
    // fields, and a CSV parser depends on that.
    Array* parts = String.withCString("a,bb,,ccc").splitOnByte((u8)',');
    Assert.isEqual(parts.count(), (u16)4);                          // T8a
    Assert.isTrue(((String*)parts.get((u16)0)).equals(String.withCString("a")));
    Assert.isTrue(((String*)parts.get((u16)1)).equals(String.withCString("bb")));
    Assert.isTrue(((String*)parts.get((u16)2)).isEmpty());          // T8b — the gap
    Assert.isTrue(((String*)parts.get((u16)3)).equals(String.withCString("ccc")));

    // No separator at all: one component, the whole string.
    Array* one = String.withCString("solo").splitOnByte((u8)',');
    Assert.isEqual(one.count(), (u16)1);                            // T8c

    // ── T9: join round-trips it.
    String* joined = String.join(parts, String.withCString(","));
    Assert.isTrue(joined.equals(String.withCString("a,bb,,ccc")));   // T9a

    String* dashed = String.join(parts, String.withCString("-"));
    Assert.isTrue(dashed.equals(String.withCString("a-bb--ccc")));   // T9b

    // ── T10: replacing.
    String* r = String.withCString("one two one");
    Assert.isTrue(r.replacing(String.withCString("one"), String.withCString("1"))
                   .equals(String.withCString("1 two 1")));          // T10a
    Assert.isTrue(r.equals(String.withCString("one two one")));      // T10b — untouched
    // A replacement that is longer than the needle, and one that is empty.
    Assert.isTrue(String.withCString("aXa").replacing(String.withCString("X"), String.withCString("YY"))
                   .equals(String.withCString("aYYa")));             // T10c
    Assert.isTrue(String.withCString("aXa").replacing(String.withCString("X"), String.withCString(""))
                   .equals(String.withCString("aa")));               // T10d

    // ── T11: ordering.
    Assert.isEqual((i16)String.withCString("apple").compare(String.withCString("banana")), (i16)-1);  // T11a
    Assert.isEqual((i16)String.withCString("banana").compare(String.withCString("apple")), (i16)1);
    Assert.isEqual((i16)String.withCString("same").compare(String.withCString("same")), (i16)0);
    // A prefix sorts before its extension.
    Assert.isEqual((i16)String.withCString("go").compare(String.withCString("gone")), (i16)-1);       // T11b
}

void main(void)
{
    t1_t2();
    t3_t4();
    t5_t6_t7();
    t8_t9_t10_t11();
    Assert.summary();
    return;
}
