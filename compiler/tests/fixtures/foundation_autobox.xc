// foundation_autobox.xc — sema autoboxing of primitive arguments
// where the parameter expects an Object@-ish type.
//
// Without autoboxing the user has to write `arr.add(Number.with(42))`
// every time. With it, `arr.add(42)` synthesises the
// `Number.with(42)` factory at the call site, picks the right
// Number factory by overload (i8/u8/i16/u16/i32/u32/float), and
// passes the resulting Number@ to add(Object@). String literals
// box into String via String.withCString.
//
// Coverage:
//   T1   Array.add(u16) + Array.add(string-literal) boxes both —
//        count() reflects two entries.
//   T2   Round-trip: a.get(0) returns Number@, a.get(1) returns
//        String@. Stored values come back unchanged.
//   T3   Map.set(string-literal, u16-literal) — both key and
//        value autobox.
//   T4   Map.get(string-literal) — argument autoboxes to a probe
//        String@ that compares equal to the boxed key.
//   T5   contains() / remove(): probe with primitive autoboxes
//        and finds the entry.
//
// Set's autobox path runs through the same `add(Hashable@)` /
// `contains(Hashable@)` machinery as Map's `set` and is covered
// transitively by foundation_set_basic + foundation_set_arc once
// users start writing primitive args.
//
// Heap-capable targets only.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    // ── T1: Array autoboxing (one int + one string literal) ────
    Array* a = new Array();
    a.add((u16)1234);
    a.add("hi");
    Assert.isEqual(a.count(), (u16)2);                           // T1

    // ── T2: round-trip ─────────────────────────────────────────
    Number* n0 = (Number* ?)a.get((u16)0);
    Assert.isEqual(n0.asU16(), (u16)1234);                       // T2a
    String* s1 = (String* ?)a.get((u16)1);
    String* probe = String.withCString("hi");
    Assert.isTrue(s1.equals(probe));                             // T2b

    // ── T3 / T4: Map autoboxing on both key and value ──────────
    Map* m = new Map();
    m.set("name", (u16)42);
    Assert.isEqual(m.count(), (u16)1);                           // T3
    Number* got = (Number* ?)m.get("name");
    Assert.isEqual(got.asU16(), (u16)42);                        // T4

    // ── T5: contains / remove with primitive probes ────────────
    Assert.isTrue(m.contains("name"));                           // T5a
    Assert.isFalse(m.contains("missing"));                       // T5b
    m.remove("name");
    Assert.isEqual(m.count(), (u16)0);                           // T5c

    Assert.summary();
    return;
}
