// string_mutate.xc — String splices in place now.
//
// self-hosting M2. M1's delta (private:docs/Design/m1-foundation-surface.md) listed
// "mutation in place" as one of the String gaps: the class grew and appended,
// but replaceCharactersInRange: / setString: / deleteCharactersInRange: /
// replaceOccurrencesOfString: had no equivalent at all — 1,640 NSMutableString
// call sites depend on that shape.
//
//   T1  insert — before, middle, at the end, past the end (clamps to append)
//   T2  insertChar / insertCString
//   T3  deleteRange — middle, clamped length, past the end, whole string
//   T4  replaceRange — shorter, longer and same-length replacements
//   T5  setTo / setCString / clear, and clear KEEPING the buffer
//   T6  replaceOccurrences — the count it returns, a replacement containing
//       the needle (must terminate), an empty replacement, a needle absent
//   T7  splicing a String into ITSELF — the aliasing case that reads freed
//       memory if the buffer is reallocated out from under the source
//   T8  indexOf(needle, from) — scan without allocating a substring per step
//   T9  appendBytes

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void t1_t2(void)
{
    // ── T1: insert.
    String* s = String.withCString("helloworld");
    s.insertAtByte((u16)5, String.withCString(", "));
    Assert.isTrue(s.equals(String.withCString("hello, world")));       // T1a

    s.insertAtByte((u16)0, String.withCString(">> "));
    Assert.isTrue(s.equals(String.withCString(">> hello, world")));    // T1b

    s.insertAtByte((u16)s.byteLength(), String.withCString("!"));
    Assert.isTrue(s.equals(String.withCString(">> hello, world!")));   // T1c

    // Past the end clamps to an append rather than faulting.
    s.insertAtByte((u16)999, String.withCString("?"));
    Assert.isTrue(s.equals(String.withCString(">> hello, world!?")));  // T1d

    // Inserting nothing is a no-op, and null is not a crash.
    String* before = String.withString(s);
    s.insertAtByte((u16)3, String.withCString(""));
    s.insertAtByte((u16)3, (String*)0);
    Assert.isTrue(s.equals(before));                                   // T1e

    // ── T2: the char and C-string forms.
    String* c = String.withCString("ac");
    c.insertByte((u16)1, (u8)'b');
    Assert.isTrue(c.equals(String.withCString("abc")));                // T2a

    c.insertCStringAtByte((u16)3, "def");
    Assert.isTrue(c.equals(String.withCString("abcdef")));             // T2b
    Assert.isEqual((u16)c.byteLength(), (u16)6);
}

void t3_t4(void)
{
    // ── T3: deleteRange.
    String* s = String.withCString("hello, world");
    s.deleteByteRange((u16)5, (u16)2);
    Assert.isTrue(s.equals(String.withCString("helloworld")));         // T3a
    Assert.isEqual((u16)s.byteLength(), (u16)10);

    // A length past the end clamps to "to the end".
    s.deleteByteRange((u16)5, (u16)999);
    Assert.isTrue(s.equals(String.withCString("hello")));              // T3b

    // A start past the end deletes nothing.
    s.deleteByteRange((u16)99, (u16)3);
    Assert.isTrue(s.equals(String.withCString("hello")));              // T3c

    s.deleteByteRange((u16)0, (u16)5);
    Assert.isTrue(s.isEmpty());                                        // T3d
    Assert.isEqual((u16)s.cString()[0], (u16)0);                       // still terminated

    // ── T4: replaceRange, all three length relationships.
    String* r = String.withCString("the quick fox");
    r.replaceByteRange((u16)4, (u16)5, String.withCString("slow"));        // shorter
    Assert.isTrue(r.equals(String.withCString("the slow fox")));       // T4a

    r.replaceByteRange((u16)4, (u16)4, String.withCString("extremely nimble"));
    Assert.isTrue(r.equals(String.withCString("the extremely nimble fox")));  // T4b

    r.replaceByteRange((u16)0, (u16)3, String.withCString("one"));         // same length
    Assert.isTrue(r.equals(String.withCString("one extremely nimble fox")));  // T4c

    // A null replacement is a delete.
    r.replaceByteRange((u16)0, (u16)4, (String*)0);
    Assert.isTrue(r.equals(String.withCString("extremely nimble fox")));      // T4d
}

void t5(void)
{
    // ── T5: setTo / setCString / clear.
    String* s = String.withCString("");
    for (u16 i = (u16)0; i < (u16)100; i = i + (u16)1) s.appendByte((u8)'z');
    u16 cap = (u16)s.capacity();

    s.clear();
    Assert.isTrue(s.isEmpty());                                        // T5a
    Assert.isEqual((u16)s.byteLength(), (u16)0);
    // The BUFFER survives the clear — that is the point of it. A scratch
    // accumulator reused per round then costs one allocation, not one a round.
    Assert.isEqual((u16)s.capacity(), cap);                            // T5b

    s.setTo(String.withCString("abc"));
    Assert.isTrue(s.equals(String.withCString("abc")));                // T5c
    Assert.isEqual((u16)s.capacity(), cap);                            // still no realloc

    s.setCString("wxyz");
    Assert.isTrue(s.equals(String.withCString("wxyz")));               // T5d

    // setTo(self) is a no-op, not a self-clobber.
    s.setTo(s);
    Assert.isTrue(s.equals(String.withCString("wxyz")));               // T5e
}

void t6(void)
{
    // ── T6: replaceOccurrences, the in-place twin of `replacing`.
    String* s = String.withCString("one two one three one");
    Assert.isEqual((u16)s.replaceOccurrences(String.withCString("one"),
                                             String.withCString("1")), (u16)3);   // T6a
    Assert.isTrue(s.equals(String.withCString("1 two 1 three 1")));    // T6b

    // A replacement CONTAINING the needle terminates — the scan resumes after
    // the substitution, not inside it.
    String* g = String.withCString("aXa");
    Assert.isEqual((u16)g.replaceOccurrences(String.withCString("a"),
                                             String.withCString("aa")), (u16)2);  // T6c
    Assert.isTrue(g.equals(String.withCString("aaXaa")));              // T6d

    // An empty replacement deletes.
    String* d = String.withCString("a-b-c");
    Assert.isEqual((u16)d.replaceOccurrences(String.withCString("-"),
                                             String.withCString("")), (u16)2);    // T6e
    Assert.isTrue(d.equals(String.withCString("abc")));

    // Absent needle: no edit, count zero. Empty needle: likewise, rather than
    // an infinite loop.
    String* n = String.withCString("abc");
    Assert.isEqual((u16)n.replaceOccurrences(String.withCString("zz"),
                                             String.withCString("!")), (u16)0);   // T6f
    Assert.isEqual((u16)n.replaceOccurrences(String.withCString(""),
                                             String.withCString("!")), (u16)0);   // T6g
    Assert.isTrue(n.equals(String.withCString("abc")));

    // The non-mutating twin still works, and still leaves the receiver alone.
    String* keep = String.withCString("x.y.z");
    Assert.isTrue(keep.replacing(String.withCString("."), String.withCString("/"))
                      .equals(String.withCString("x/y/z")));           // T6h
    Assert.isTrue(keep.equals(String.withCString("x.y.z")));           // T6i
}

void t7_t8_t9(void)
{
    // ── T7: aliasing. Splicing a String into itself reads from a buffer the
    // splice may already have grown — and freed. Each of these copies first.
    String* a = String.withCString("ab");
    a.insertAtByte((u16)0, a);
    Assert.isTrue(a.equals(String.withCString("abab")));               // T7a

    String* b = String.withCString("xy");
    b.replaceByteRange((u16)1, (u16)1, b);
    Assert.isTrue(b.equals(String.withCString("xxy")));                // T7b

    String* c = String.withCString("mm");
    Assert.isEqual((u16)c.replaceOccurrences(String.withCString("m"), c), (u16)2); // T7c
    Assert.isTrue(c.equals(String.withCString("mmmm")));               // T7d

    // ── T8: offset search.
    String* h = String.withCString("aa bb aa bb");
    String* aa = String.withCString("aa");
    Assert.isEqual((u16)h.byteIndexOf(aa), (u16)0);                        // T8a
    Assert.isEqual((u16)h.byteIndexOf(aa, (u16)1), (u16)6);                // T8b
    // No (u16) narrowing here: notFound() is the full-width sentinel, so a cast
    // on one side only would compare $0000FFFF against $FFFFFFFF.
    Assert.isEqual(h.byteIndexOf(aa, (u16)7), String.notFound());          // T8c
    Assert.isEqual(h.byteIndexOf(aa, (u16)999), String.notFound());        // T8d — past end

    // ── T9: appendBytes takes raw bytes, no NUL needed.
    u8 raw[4];
    raw[0] = (u8)'w'; raw[1] = (u8)'x'; raw[2] = (u8)'y'; raw[3] = (u8)'z';
    String* acc = String.withCString("v");
    acc.appendBytes(&raw[0], (u16)3);
    Assert.isTrue(acc.equals(String.withCString("vwxy")));             // T9a
    Assert.isEqual((u16)acc.cString()[4], (u16)0);                     // T9b — terminated
}

void main(void)
{
    t1_t2();
    t3_t4();
    t5();
    t6();
    t7_t8_t9();
    Assert.summary();
    return;
}
