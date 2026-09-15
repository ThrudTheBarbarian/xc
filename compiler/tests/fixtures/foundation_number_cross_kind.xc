// foundation_number_cross_kind.xc — Number's lazy cross-kind cache
// and the equals() promotion that depends on it.
//
// Verifies that:
//   T1-T5   asFloat() on an Int Number faults in (float)_i and
//           returns the correctly-typed float.
//   T6-T10  asI32 / asI16 / asI8 / asU32 / asU16 on a Float Number
//           fault in via fpToI32 (truncate toward zero).
//   T11-T13 setXxx after a fault-in invalidates the cached slot —
//           a subsequent cross-kind getter must reconvert from
//           the new canonical value, not return the stale cache.
//   T14-T17 equals() with same-kind operands still bit-exact.
//   T18-T22 equals() across kinds promotes both sides to float
//           and compares: Int(42) == Float(42.0), Int(-3) ==
//           Float(-3.0), Int(0) == Float(0.0); fractional floats
//           never compare equal to any int.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    // ── Cross-kind getter on Int Number ───────────────────────────
    Number* ni = Number.withI16((i16)42);
    Assert.isTrue(ni.asI16() == 42);                            // T1 — same-kind exact
    Assert.isTrue(ni.asFloat() == 42.0);                        // T2 — int→float fault-in
    Assert.isTrue(ni.asFloat() == 42.0);                        // T3 — second call hits cache
    Assert.isTrue(ni.asI16() == 42);                            // T4 — int slot still intact
    Assert.isTrue(ni.isInt());                                  // T5 — kind unchanged by getter

    // ── Cross-kind getter on Float Number ─────────────────────────
    Number* nf = Number.withFloat(-3.7);
    Assert.isTrue(nf.asFloat() == -3.7);                        // T6 — same-kind exact
    Assert.isTrue(nf.asI32() == -3);                            // T7 — float→int truncate toward zero
    Assert.isTrue(nf.asI16() == -3);                            // T8 — narrow getter, cached _i
    Assert.isTrue(nf.asI8()  == -3);                            // T9
    Assert.isTrue(nf.isFloat());                                // T10 — kind unchanged

    // ── Reassignment invalidates the cache ────────────────────────
    Number* nr = Number.withI16((i16)10);
    Assert.isTrue(nr.asFloat() == 10.0);                        // T11 — fault in _f as 10.0
    nr.setI16((i16)99);
    Assert.isTrue(nr.asFloat() == 99.0);                        // T12 — must NOT return stale 10.0
    nr.setFloat(0.5);
    Assert.isTrue(nr.asI32() == 0);                             // T13 — float→int truncates 0.5 → 0

    // ── Same-kind equals (regression) ─────────────────────────────
    Number* a = Number.withI16((i16)42);
    Number* b = Number.withI16((i16)42);
    Number* c = Number.withI16((i16)99);
    Number* fa = Number.withFloat(3.14);
    Number* fb = Number.withFloat(3.14);
    Assert.isTrue(a.equals(b));                                 // T14
    Assert.isFalse(a.equals(c));                                // T15
    Assert.isTrue(fa.equals(fb));                               // T16
    Assert.isFalse(fa.equals(Number.withFloat(2.71)));          // T17

    // ── Cross-kind equals via float promotion ─────────────────────
    Number* i42 = Number.withI16((i16)42);
    Number* f42 = Number.withFloat(42.0);
    Number* f42p5 = Number.withFloat(42.5);
    Number* i0 = Number.withI16((i16)0);
    Number* f0 = Number.withFloat(0.0);
    Number* ineg3 = Number.withI16((i16)-3);
    Number* fneg3 = Number.withFloat(-3.0);

    Assert.isTrue(i42.equals(f42));                             // T18 — Int(42) == Float(42.0)
    Assert.isFalse(i42.equals(f42p5));                          // T19 — Int(42) ≠ Float(42.5)
    Assert.isTrue(i0.equals(f0));                               // T20 — Int(0) == Float(0.0)
    Assert.isTrue(ineg3.equals(fneg3));                         // T21 — Int(-3) == Float(-3.0)
    Assert.isTrue(f42.equals(i42));                             // T22 — symmetric

    Assert.summary();
    return;
}
