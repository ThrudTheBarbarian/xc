// foundation_comparable.xc — Comparable protocol round-trip.
//
// Verifies that:
//   T1   Number's equals(Number@) typed overload still works.
//   T2   Number's equals(Object@) Comparable slot returns true for
//        a same-value Number wrapped as Object@.
//   T3   Number's equals(Object@) returns false for a different
//        type (String) wrapped as Object@ — safe-cast catches it.
//   T4   Same as T2 / T3 but reached through a Comparable@
//        protocol pointer, so the call dispatches via the
//        protocol vtable.
//   T5   String.equals routes the same way (typed + Object@ +
//        Comparable@).
//
// Data also conforms but its tests live in foundation_data — the
// banked-heap byte-compare path has a separate documented issue
// (Data.xc's equals comment). Keep this fixture flat across every
// heap-capable target.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    // ── Number ────────────────────────────────────────────────────
    Number* n1 = Number.with((i16)42);
    Number* n2 = Number.with((i16)42);
    Number* n3 = Number.with((i16)99);
    String* sx = String.withCString("hi");

    Assert.isTrue(n1.equals(n2));                            // T1a
    Assert.isFalse(n1.equals(n3));                           // T1b

    Object* on2 = n2;
    Object* on3 = n3;
    Object* osx = sx;
    Assert.isTrue(n1.equals(on2));                           // T2a — same value via Object@
    Assert.isFalse(n1.equals(on3));                          // T2b — different value
    Assert.isFalse(n1.equals(osx));                          // T3 — type mismatch

    Comparable* cn1 = n1;
    Comparable* cn2 = n2;
    Comparable* cn3 = n3;
    Comparable* csx = sx;
    Assert.isTrue(cn1.equals(on2));                          // T4a — through protocol vtable
    Assert.isFalse(cn1.equals(on3));                         // T4b
    Assert.isFalse(cn1.equals(osx));                         // T4c

    // ── String ────────────────────────────────────────────────────
    String* s1 = String.withCString("hello");
    String* s2 = String.withCString("hello");
    String* s3 = String.withCString("world");

    Assert.isTrue(s1.equals(s2));                            // T5a
    Assert.isFalse(s1.equals(s3));                           // T5b

    Object* os2 = s2;
    Object* on1 = n1;
    Assert.isTrue(s1.equals(os2));                           // T5c — via Object@
    Assert.isFalse(s1.equals(on1));                          // T5d — type mismatch

    Comparable* cs1 = s1;
    Comparable* cs2 = s2;
    Assert.isTrue(cs1.equals(os2));                          // T5e — via Comparable@

    Assert.summary();
    return;
}
