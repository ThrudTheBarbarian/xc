// foundation_number_with.xc — Number's overloaded factories,
// setters, and getters.
//
// The class exposes three overload families that mirror each other:
//
//   * `with(v)`  — overloaded factory; storage kind picked by v's type.
//   * `set(v)`   — overloaded setter; same dispatch.
//   * `value()`  — return-type overloaded getter; storage extracted as
//                  the type expected by the assignment / decl context.
//
// All three sit alongside the explicit `withI8` / `setI8` / `asI8`
// (etc.) family — the typed names pin a kind regardless of the value
// or destination, the inferred forms let the compiler do the obvious
// thing.
//
// Heap-capable targets only — Number's factories use `new Number()`
// which needs the free-list allocator.

#import "Stdio.xc"
#import "Number.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    // ── with() — overloaded factories ─────────────────────────────
    Number* a = Number.with((i8)-5);
    Assert.isEqual(a.asI16(), (i16)-5);                      // T1
    Number* b = Number.with((u8)200);
    Assert.isEqual(b.asU16(), (u16)200);                     // T2
    Number* c = Number.with((i16)-1000);
    Assert.isEqual(c.asI16(), (i16)-1000);                   // T3
    Number* d = Number.with((u16)50000);
    Assert.isEqual(d.asU16(), (u16)50000);                   // T4
    Number* e = Number.with((i32)-100000);
    Assert.isEqual(e.asI32(), (i32)-100000);                 // T5
    Number* f = Number.with((u32)4000000000);
    Assert.isEqual(f.asI32(), (i32)4000000000);              // T6 — bit-preserving
    Number* g = Number.with(3.14);
    Assert.isTrue(g.isFloat());                              // T7

    // ── set() — overloaded setters ────────────────────────────────
    Number* s = new Number();
    s.set((i16)-42);
    Assert.isEqual(s.asI16(), (i16)-42);                     // T8
    s.set((u32)123456);
    Assert.isEqual(s.asI32(), (i32)123456);                  // T9
    s.set(2.5);
    Assert.isTrue(s.isFloat());                              // T10

    // ── value() — return-type overloaded getter ─────────────────
    Number* h = Number.with((i16)-77);
    i16 hv = h.value();
    Assert.isEqual(hv, (i16)-77);                            // T11

    Number* k = Number.with((u32)4000000000);
    i32 kv = k.value();
    Assert.isEqual(kv, (i32)4000000000);                     // T12 — bit-preserving via i32 value()

    // u8 storage retrieved as u16: same-kind widening.
    Number* p = Number.with((u8)200);
    u16 pv = p.value();
    Assert.isEqual(pv, (u16)200);                            // T13

    // assignment-context (existing variable) also drives the pick.
    i32 q = (i32)0;
    q = k.value();
    Assert.isEqual(q, (i32)4000000000);                      // T14

    Assert.summary();
    return;
}
