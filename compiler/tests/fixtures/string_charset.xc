// string_charset.xc — CharacterSet, and the String methods that take one.
//
// self-hosting M2. M1 (private:docs/Design/m1-foundation-surface.md) listed
// rangeOfCharacterFromSet: / componentsSeparatedByCharactersInSet: as the one
// String gap "needing a character-set notion xtc lacks entirely". A lexer is
// mostly character-class tests, so this is on the critical path for M4 rather
// than a convenience.
//
// CharacterSet is a 256-bit bitmap held INLINE as an array ivar: no allocation,
// no raw buffer to free, and — because everything in it is u8/u16 arithmetic
// over 256 values — no separate 6502 build. It is the first Foundation class
// shared verbatim by every target.
//
//   T1  membership: add / remove / addRange / contains, including at 255
//   T2  the standard sets
//   T3  inverted / formUnion / formIntersection / isEmpty
//   T4  String.indexOfCharacterFrom / lastIndexOfCharacterFrom /
//       containsCharacterFrom
//   T5  String.trimmed(set) — and the no-argument form still meaning whitespace
//   T6  String.split(set) — componentsSeparatedByCharactersInSet
//   T7  String.asCharacterSet

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void t1_t2_t3(void)
{
    // ── T1: membership.
    CharacterSet* cs = new CharacterSet();
    Assert.isTrue(cs.isEmpty());                                   // T1a
    cs.add((u8)'a');
    cs.add((u8)255);
    Assert.isTrue(cs.contains((u8)'a'));                           // T1b
    Assert.isTrue(cs.contains((u8)255));                           // T1c — the top bit
    Assert.isFalse(cs.contains((u8)'b'));
    Assert.isFalse(cs.contains((u8)0));
    Assert.isFalse(cs.isEmpty());                                  // T1d

    cs.remove((u8)'a');
    Assert.isFalse(cs.contains((u8)'a'));                          // T1e
    Assert.isTrue(cs.contains((u8)255));                           // …and only that one

    // addRange is inclusive at both ends, and terminates at the top of the
    // range rather than wrapping round to zero forever.
    CharacterSet* hi = CharacterSet.withRange((u8)250, (u8)255);
    Assert.isTrue(hi.contains((u8)250));                           // T1f
    Assert.isTrue(hi.contains((u8)255));
    Assert.isFalse(hi.contains((u8)249));

    // ── T2: the standard sets.
    Assert.isTrue(CharacterSet.decimalDigits().contains((u8)'7'));      // T2a
    Assert.isFalse(CharacterSet.decimalDigits().contains((u8)'a'));
    Assert.isTrue(CharacterSet.hexDigits().contains((u8)'f'));          // T2b
    Assert.isTrue(CharacterSet.hexDigits().contains((u8)'F'));
    Assert.isFalse(CharacterSet.hexDigits().contains((u8)'g'));
    Assert.isTrue(CharacterSet.letters().contains((u8)'Z'));            // T2c
    Assert.isFalse(CharacterSet.letters().contains((u8)'0'));
    Assert.isTrue(CharacterSet.alphanumerics().contains((u8)'0'));      // T2d
    Assert.isFalse(CharacterSet.alphanumerics().contains((u8)'_'));
    Assert.isTrue(CharacterSet.identifiers().contains((u8)'_'));        // T2e
    Assert.isTrue(CharacterSet.whitespace().contains((u8)32));          // T2f
    Assert.isFalse(CharacterSet.whitespace().contains((u8)10));         // …LF is a newline
    Assert.isTrue(CharacterSet.newlines().contains((u8)10));            // T2g
    Assert.isTrue(CharacterSet.whitespaceAndNewlines().contains((u8)10));// T2h
    Assert.isTrue(CharacterSet.whitespaceAndNewlines().contains((u8)32));

    // ── T3: set algebra.
    CharacterSet* digits = CharacterSet.decimalDigits();
    CharacterSet* notDigits = digits.inverted();
    Assert.isFalse(notDigits.contains((u8)'5'));                   // T3a
    Assert.isTrue(notDigits.contains((u8)'a'));
    Assert.isTrue(digits.contains((u8)'5'));                       // T3b — receiver untouched

    CharacterSet* u = CharacterSet.withCString("abc");
    u.formUnion(CharacterSet.withCString("cde"));
    Assert.isTrue(u.contains((u8)'a') && u.contains((u8)'e'));     // T3c

    CharacterSet* i = CharacterSet.withCString("abcd");
    i.formIntersection(CharacterSet.withCString("cdef"));
    Assert.isTrue(i.contains((u8)'c') && i.contains((u8)'d'));     // T3d
    Assert.isFalse(i.contains((u8)'a') || i.contains((u8)'e'));    // T3e
}

void t4_t5(void)
{
    String* s = String.withCString("ab12cd");
    CharacterSet* digits = CharacterSet.decimalDigits();

    // ── T4: searching by class.
    Assert.isEqual((u16)s.byteIndexOfSet(digits), (u16)2);          // T4a
    Assert.isEqual((u16)s.lastByteIndexOfSet(digits), (u16)3);      // T4b
    Assert.isTrue(s.containsByteFromSet(digits));                       // T4c

    String* letters = String.withCString("abcd");
    Assert.isEqual(letters.byteIndexOfSet(digits), String.notFound());     // T4d
    Assert.isEqual(letters.lastByteIndexOfSet(digits), String.notFound());
    Assert.isFalse(letters.containsByteFromSet(digits));                 // T4e
    // An empty string and a null set are both "no match", not a fault.
    Assert.isEqual(String.withCString("").byteIndexOfSet(digits), String.notFound()); // T4f
    Assert.isEqual(s.byteIndexOfSet((CharacterSet*)0), String.notFound());           // T4g

    // ── T5: trimming by class.
    String* padded = String.withCString("xxhelloxx");
    CharacterSet* ex = CharacterSet.withCString("x");
    Assert.isTrue(padded.trimmed(ex).equals(String.withCString("hello")));  // T5a
    Assert.isTrue(padded.equals(String.withCString("xxhelloxx")));          // T5b — untouched

    // All-trimmable trims to empty rather than underflowing.
    Assert.isTrue(String.withCString("xxx").trimmed(ex).isEmpty());         // T5c
    Assert.isTrue(String.withCString("").trimmed(ex).isEmpty());            // T5d
    // Nothing to trim.
    Assert.isTrue(String.withCString("hi").trimmed(ex).equals(String.withCString("hi"))); // T5e

    // The no-argument form still means whitespace-and-newlines.
    Assert.isTrue(String.withCString("  hi\n").trimmed().equals(String.withCString("hi"))); // T5f
    Assert.isTrue(String.withCString("  hi\n")
                    .trimmed(CharacterSet.whitespaceAndNewlines())
                    .equals(String.withCString("hi")));                     // T5g
}

void t6_t7(void)
{
    // ── T6: splitting on a class. Consecutive separators still yield empty
    // components, exactly as split(u8) does — a CSV depends on it.
    CharacterSet* seps = CharacterSet.withCString(",;");
    Array* parts = String.withCString("a,b;c").splitOnSet(seps);
    Assert.isEqual((u16)parts.count(), (u16)3);                             // T6a
    Assert.isTrue(((String*)parts.get((u16)0)).equals(String.withCString("a")));
    Assert.isTrue(((String*)parts.get((u16)2)).equals(String.withCString("c")));

    Array* gapped = String.withCString("a,,b").splitOnSet(seps);
    Assert.isEqual((u16)gapped.count(), (u16)3);                            // T6b
    Assert.isTrue(((String*)gapped.get((u16)1)).isEmpty());                 // T6c

    // No separator at all: one component, the whole string.
    Assert.isEqual((u16)String.withCString("solo").splitOnSet(seps).count(), (u16)1);  // T6d
    // A null set likewise yields the whole string.
    Assert.isEqual((u16)String.withCString("solo").splitOnSet((CharacterSet*)0).count(), (u16)1); // T6e

    // Splitting on a class is what tokenising whitespace-separated text wants.
    Array* words = String.withCString("one two\tthree").splitOnSet(CharacterSet.whitespaceAndNewlines());
    Assert.isEqual((u16)words.count(), (u16)3);                             // T6f
    Assert.isTrue(((String*)words.get((u16)2)).equals(String.withCString("three")));

    // ── T7: a String as a set of its own characters.
    CharacterSet* vowels = String.withCString("aeiou").asCharacterSet();
    Assert.isTrue(vowels.contains((u8)'e'));                                // T7a
    Assert.isFalse(vowels.contains((u8)'z'));                               // T7b
}

void main(void)
{
    t1_t2_t3();
    t4_t5();
    t6_t7();
    Assert.summary();
    return;
}
