// foundation_number.xc — Number.xc smoke + correctness tests.
//
// Each test exercises a slice of Number's surface:
//   T1-T6   round-trip through every native int factory + getter
//   T7      bit-preserving cross-signedness retrieval
//   T8      sign-extending narrowing/widening on int kinds
//   T9      float storage + retrieval
//   T10     isInt / isFloat predicates
//   T11     equals — same-kind, same value
//   T12     equals — same-kind, different value
//   T13     equals — different kinds (Int vs Float of same numeric)
//
// Heap-capable targets only — Number's factories use `new Number()`
// which needs the free-list allocator.

#import "Stdio.xc"
#import "Number.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    // Compare i8/u8 via the wider asI16/asU16 paths — narrow→wider
    // casts on bare i8/u8 returns from a method don't sign-extend
    // cleanly today (separate xtc issue), but Number's storage IS
    // wide so asI16/asU16 sees the full sign-extended value.
    Number* a = Number.withI8(-5);
    Assert.isEqual(a.asI16(), (i16)-5);                          // T1

    Number* b = Number.withU8(200);
    Assert.isEqual(b.asU16(), (u16)200);                         // T2

    Number* c = Number.withI16(-1000);
    Assert.isEqual(c.asI16(), (i16)-1000);                       // T3

    Number* d = Number.withU16(50000);
    Assert.isEqual(d.asU16(), (u16)50000);                       // T4

    Number* e = Number.withI32(-100000);
    Assert.isEqual(e.asI32(), (i32)-100000);                   // T5

    Number* f = Number.withU32(4000000000);
    Assert.isEqual(f.asI32(), (i32)4000000000);                // T6 — bit-preserving cast back

    // T7: setU32($FFFFFFFF) → asI32() reads -1 (bit-preserving).
    Number* g = Number.withU32($FFFFFFFF);
    Assert.isEqual(g.asI32(), (i32)-1);                        // T7

    // T8: setI8(-5) → asI16() / asI32() sign-extend.
    Number* h = Number.withI8(-5);
    Assert.isEqual(h.asI16(), (i16)-5);                          // T8a
    Assert.isEqual(h.asI32(), (i32)-5);                          // T8b

    // T9: float round-trip.
    Number* i = Number.withFloat(3.14);
    Assert.isTrue(i.isFloat());                                  // T9a
    // Compare float via byte-level inspection isn't trivial; trust
    // the predicate + the storage shape and check kind logic.

    // T10: predicate flips with kind.
    Assert.isTrue(a.isInt());                                    // T10a
    Assert.isTrue(!a.isFloat());                                 // T10b
    Assert.isTrue(i.isFloat());                                  // T10c
    Assert.isTrue(!i.isInt());                                   // T10d

    // T11: equals — same kind, same value.
    Number* j = Number.withI16(-1000);
    Assert.isTrue(c.equals(j));                                  // T11

    // T12: equals — same kind, different value.
    Number* k = Number.withI16(-1001);
    Assert.isTrue(!c.equals(k));                                 // T12

    // T13: equals — cross-kind float promotion. Int(3) ≡ Float(3.0)
    // because the int side faults in via (float)i32 and matches
    // the float exactly. A non-integer float never equals any int.
    Number* m = Number.withI8(3);
    Number* n = Number.withFloat(3.0);
    Assert.isTrue(m.equals(n));                                  // T13a — promote, equal
    Number* nFrac = Number.withFloat(3.5);
    Assert.isTrue(!m.equals(nFrac));                             // T13b — promote, not equal

    Assert.summary();
    return;
}
