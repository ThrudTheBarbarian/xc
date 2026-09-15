// arc_array_of_strong_struct.xc — stack arrays of strong-
// bearing structs get zero-init, element-wise scope-exit
// release, and release-old on direct field assignment.
//
// Before this landing, `Holder arr[N]` where
// `struct Holder { Item@ payload; ... }` had no ARC wiring:
//   • arcMaybeTrackLocal's stack-array branch required the
//     array element type to be a strong class pointer
//     directly — struct elements fell through.
//   • No zero-init meant a stray non-zero first byte in the
//     payload slot would look like a valid pointer.
//   • Scope exit didn't register the array for cleanup, so
//     every live element leaked its strong ivars.
//   • `arr[i].field = new X()` had no release-old path for
//     subscript bases, so overwriting a live element leaked
//     the previous value's refcount.
//
// This fixture covers:
//   • Scope-exit walks every element at `i * structWidth`
//     and invokes the struct-field walker (which itself
//     recurses into nested strong-bearing structs).
//   • The null-check inside the walker skips unwritten
//     elements (zero-init guarantees they read as 0).
//   • Direct field-assign `arr[i].payload = new Item()`
//     fires the release-old / retain-new / store sequence.
//   • Nested strong-bearing struct elements (`Outer arr[N]`
//     where `struct Outer { Holder h; ... }`) walk through
//     the nested path.
//
// Flat-heap targets only — banked arrays of strong-bearing
// structs would need indirect addressing through 3-byte
// banked pointers (Phase 4).

#import "Stdio.xc"
#import "Assert.xc"

u16 itemDealloc;

class Item
{
    u8 id;
    void dealloc(void) { itemDealloc = itemDealloc + 1; }
}

struct Holder
{
    Item* payload;
    u16   mark;
}

struct Outer
{
    Holder h;
    u16    tag;
}

void populateFlat(void)
{
    Holder harr[4];
    harr[0].payload = new Item();
    harr[1].payload = new Item();
    harr[2].payload = new Item();
    // harr[3] stays null — zero-init + null-check guarantee
    // no spurious release at scope exit.
    return;
}

void populateNested(void)
{
    Outer oarr[2];
    oarr[0].h.payload = new Item();
    oarr[1].h.payload = new Item();
    return;
}

void replaceInArray(void)
{
    Holder harr[3];
    harr[0].payload = new Item();
    Assert.isEqual(itemDealloc, 0);                   // T3: slot was null
    harr[0].payload = new Item();
    Assert.isEqual(itemDealloc, 1);                   // T4: release-old fires
    harr[1].payload = new Item();
    harr[2].payload = new Item();
    return;
}

void main(void)
{
    Assert.reset();

    // ── T1: 3-of-4 elements alive, 1 null-skipped ─────────
    itemDealloc = 0;
    populateFlat();
    Assert.isEqual(itemDealloc, 3);                   // T1

    // ── T2: nested strong-bearing struct element walker ───
    itemDealloc = 0;
    populateNested();
    Assert.isEqual(itemDealloc, 2);                   // T2

    // ── T3-T5: release-old on direct field-assign + exit ──
    itemDealloc = 0;
    replaceInArray();
    // 1 release-old (T4) + 3 scope-exit = 4 total deallocs.
    Assert.isEqual(itemDealloc, 4);                   // T5

    Assert.summary();
    return;
}
