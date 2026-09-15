// foundation_hashable.xc — Hashable protocol smoke tests.
//
// Equal keys must hash equally (the hash contract). Non-equal
// keys are allowed to collide; we just verify a few cases that
// SHOULDN'T collide do produce distinct codes, so a hash that
// degenerated to a constant gets caught.
//
//   T1   Number int hash is stable across two distinct Number
//        instances of the same value.
//   T2   Number cross-kind: Int(42) hashes the same as Float(42.0).
//   T3   Two distinct Number values are unlikely to collide
//        (sanity check; hash is not constant).
//   T4   String hash is stable, and identical content hashes the
//        same across two distinct String instances.
//   T5   Different strings produce different hashes (sanity).
//   T6   Data hash matches String hash for the same byte sequence
//        — both use the same XOR-rotate fold.
//
// Heap-capable targets only — Number / String / Data are heap.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    // ── T1: Number int hash stable ────────────────────────────────
    Number* a = Number.withI16(42);
    Number* b = Number.withI16(42);
    Assert.isEqual((u16)a.hash(), (u16)b.hash());                // T1

    // ── T2: cross-kind Int / Float hash agreement ─────────────────
    Number* ai = Number.withI16(42);
    Number* af = Number.withFloat(42.0);
    Assert.isTrue(ai.equals(af));     // sanity: cross-kind equal
    Assert.isEqual((u16)ai.hash(), (u16)af.hash());              // T2

    // ── T3: distinct values, distinct hashes (sanity) ─────────────
    Number* x = Number.withI16(1);
    Number* y = Number.withI16(257);
    Assert.isFalse(x.hash() == y.hash());                        // T3

    // ── T4: String hash stable across instances ───────────────────
    String* s1 = String.withCString("hello");
    String* s2 = String.withCString("hello");
    Assert.isEqual((u16)s1.hash(), (u16)s2.hash());              // T4

    // ── T5: distinct strings, distinct hashes (sanity) ────────────
    String* s3 = String.withCString("world");
    Assert.isFalse(s1.hash() == s3.hash());                      // T5

    // ── T6: Data and String share the fold over the same bytes ───
    u8 src[5];
    src[0] = (u8)$68;  // 'h'
    src[1] = (u8)$65;  // 'e'
    src[2] = (u8)$6C;  // 'l'
    src[3] = (u8)$6C;  // 'l'
    src[4] = (u8)$6F;  // 'o'
    Data* d = Data.withBytes(&src[0], (u16)5);
    Assert.isEqual((u16)d.hash(), (u16)s1.hash());               // T6

    Assert.summary();
    return;
}
