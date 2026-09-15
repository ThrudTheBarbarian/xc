// arc_arr_struct_return.xc — ARC for `arr[i] = f()` where f
// returns a struct.
//
// Before this landing the codegen errored out at the call site:
// "only StructType v = f(...) and v = f(...) forms are supported".
// The subscript-LHS + struct-return shape simply wasn't wired —
// meaning `arr[i] = makeHolder();` couldn't be written at all,
// let alone with strong-field ARC plumbing.
//
// This fixture proves three things:
//   1. Large struct (>8B) return into arr[i] via the retbuf
//      path. Element address is computed after arg push and
//      passed as __retbuf. Works for ARC-irrelevant structs
//      (Point, u16 fields only).
//   2. Small struct (≤8B) return into arr[i] via $B0..$B7 byte-
//      copy. Requires constant index (dynamic index would clobber
//      $B0..$B3 via u16Mul; diagnosed).
//   3. Strong-field struct return into arr[i] releases the
//      element's old strong fields before the call overwrites
//      them — exercises the ARC path end-to-end.
//
// Field access through arr[i].field has a pre-existing codegen
// limit (offset computation doesn't project through the subscript
// read), so verification uses struct-copy into a local. That path
// works correctly and re-exercises arr[i] = arr[j] too.
//
// Flat-heap only — banked-heap ARC is Phase 4.

#import "Stdio.xc"
#import "Assert.xc"

u16 itemDealloc;

class Item
{
    u8 id;
    void dealloc(void) { itemDealloc = itemDealloc + 1; }
}

// Large: > 8 bytes, forces retbuf lowering.
struct Large
{
    u16 a; u16 b; u16 c; u16 d; u16 e;
}

// Small: 3 bytes, stays in $B0..$B7.
struct Small
{
    u16 id;
    u8  tag;
}

// Strong-field struct: tests ARC release-old.
struct Holder
{
    Item* payload;
    u16   mark;
}

Large makeLarge(u16 seed)
{
    Large v;
    v.a = seed;
    v.b = seed + 1;
    v.c = seed + 2;
    v.d = seed + 3;
    v.e = seed + 4;
    return v;
}

Small makeSmall(u8 tag)
{
    Small v;
    v.id  = 1000;
    v.tag = tag;
    return v;
}

Holder makeHolder(u8 id)
{
    Holder h;
    h.payload = new Item();
    h.payload.id = id;
    h.mark = 777;
    return h;
}

void main(void)
{
    Assert.reset();
    itemDealloc = 0;

    // ── T1-T3: large-struct retbuf path ───────────────────
    Large larr[3];
    larr[0] = makeLarge(10);
    larr[1] = makeLarge(20);
    larr[2] = makeLarge(30);

    Large lcheck;
    lcheck = larr[0];
    Assert.isEqual(lcheck.a, 10);                     // T1
    lcheck = larr[1];
    Assert.isEqual(lcheck.b, 21);                     // T2
    lcheck = larr[2];
    Assert.isEqual(lcheck.e, 34);                     // T3

    // ── T4-T5: small-struct $B0..$B7 path (const index) ──
    Small sarr[3];
    sarr[0] = makeSmall(7);
    sarr[2] = makeSmall(77);

    Small scheck;
    scheck = sarr[0];
    Assert.isEqual(scheck.id, 1000);                  // T4
    scheck = sarr[2];
    Assert.isEqual((u16)scheck.tag, 77);              // T5

    // ── T6-T7: strong-field struct — ARC release-old ─────
    Holder harr[3];
    harr[0] = makeHolder(42);                         // slot was null — no release
    Assert.isEqual(itemDealloc, 0);                   // T6

    harr[0] = makeHolder(99);                         // slot had Item#42 — release fires
    Assert.isEqual(itemDealloc, 1);                   // T7

    // scope-exit releases harr[0].payload and harr[1..2] (null).
    Assert.summary();
    return;
}
