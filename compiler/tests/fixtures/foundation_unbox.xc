// foundation_unbox.xc — sema unboxing of class-pointer values into
// primitive destinations. Symmetric to foundation_autobox.
//
// Without unboxing the user has to write
//   `i32 v = ((Number@)arr.get(0)).asI32();`
// every time. With it, a primitive-typed destination paired with a
// class-pointer source lets sema splice the
// `((Number@)expr).asXXX()` rewrite in automatically. The accessor
// is picked from the destination type (asI8/asU8/.../asFloat).
//
// Coverage:
//   T1   Variable decl-init: `i32 v = arr.get(0)` extracts via
//        Number.asI32. Boxed input is u16 100; round-trip widens.
//   T2   Decl-init: `u16 v = m.get("k")`.
//   T3   Decl-init via different accessor widths from same Number.
//   T4   Plain assignment: `v = arr.get(i);`
//   T5   Function return: a u16-returning function `return
//        arr.get(0);` unboxes to u16.
//   T6   Function arg: passing arr.get(i) where the param is u16.
//
// Heap-capable targets only.

#import "Foundation.xc"
#import "Stdio.xc"
#import "Assert.xc"

void takesU16(u16 v)
{
    Assert.isEqual(v, (u16)100);
}

u16 readBoxedU16(Array* a)
{
    return a.get((u16)0);   // Object@ → u16 unbox at the return site
}

void main(void)
{
    Assert.reset();

    // ── Setup: a heterogeneous Array via autobox so the get()s
    //          below have something to unbox.
    Array* a = new Array();
    a.add((u16)100);   // boxed Number@
    a.add((u16)200);
    a.add((i32)-1234567);

    // ── T1: i32 destination from Object@ via decl-init ─────────
    i32 v0 = a.get((u16)2);                                        // T1
    Assert.isEqual(v0, (i32)-1234567);

    // ── T2: u16 destination from Map's Object@ via decl-init ───
    Map* m = new Map();
    m.set("k", (u16)42);
    u16 v1 = m.get("k");                                           // T2
    Assert.isEqual(v1, (u16)42);

    // ── T3: same Number-bearing slot, different accessor widths ─
    a.add((u16)9);
    u16 wU16 = a.get((u16)3);
    i32 wI32 = a.get((u16)3);
    Assert.isEqual(wU16, (u16)9);                                  // T3a
    Assert.isEqual(wI32, (i32)9);                                  // T3b

    // ── T4: plain assignment ───────────────────────────────────
    u16 dst = (u16)0;
    dst = a.get((u16)0);                                           // T4
    Assert.isEqual(dst, (u16)100);

    // ── T5: function return unbox ──────────────────────────────
    u16 r = readBoxedU16(a);                                       // T5
    Assert.isEqual(r, (u16)100);

    // ── T6: function arg unbox ─────────────────────────────────
    takesU16(a.get((u16)0));                                       // T6

    Assert.summary();
    return;
}
