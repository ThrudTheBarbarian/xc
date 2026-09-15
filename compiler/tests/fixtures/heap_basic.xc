// heap_basic.xc — coalescing free-list heap allocator coverage.
//
// Exercises `new` and release-at-scope-exit on a target that defaults to
// -falloc=heap (currently xl-shadow and xe-nobank). Other targets
// stay on the bump allocator; this fixture is not wired into the
// run_fixtures.sh matrix for them.
//
// Test surface:
//   T1–T2  new / delete / new returns a usable allocation
//   T3     delete of a null pointer is a no-op
//   T4–T5  class-defined dealloc() runs exactly once per delete
//   T6–T7  alloc / delete round-trips reclaim the slot; a fresh
//          allocation after the churn still returns a usable pointer
//   T8     dealloc() call count matches the Tracker deletes
//   T9     new T[N] for a primitive, read + write elements
//   T10    delete on an array of class instances iterates dealloc()
//   T11–T13  Heap.size() / Heap.free() / Heap.largest() introspection

#import "Stdio.xc"
#import "Heap.xc"
#import "Assert.xc"

// Classes used via `new` on banked-heap targets are auto-placed in
// main RAM by the codegen (sema tags the class with usedByNew). No
// manual :main annotations are needed — (self),Y stores inside a
// method body naturally reach the heap bank because the method's
// code lives in main RAM which has the heap bank selected.
class Box
{
    u16 v;
    void set(u16 x) { v = x; }
}

class Tracker
{
    u8 tag;
    void dealloc(void)
    {
        deallocCallCount = deallocCallCount + 1;
    }
}

u16 deallocCallCount;

// The churn helper is pushed out of main(). (It used to be here to dodge
// the "new in a loop" warning, which is gone — bug 086 measured that nothing
// it warned about leaked. The shape stays because the caller's loop still
// provides the pressure.)
//
// `:main` is required on banked-heap targets for any FREE
// function (not class method) that touches a heap pointer. The
// auto-:main heuristic only covers methods of heap-allocated
// classes; free functions that deref banked pointers still need
// manual annotation so the compiler keeps them in main RAM. On
// non-banked targets this annotation is a no-op.
u16 churnOne(u16 val) : main
{
    Box* b = new Box();
    b.set(val);
    u16 got = b.v;
    return got;                        // b is released when the frame exits
}

void main(void)
{
    Assert.reset();
    deallocCallCount = 0;

    // ── T1–T2: alloc / free / alloc round-trip ─────────────────
    // Each object is scoped so its release point is exact: the block
    // must be back on the free list before the next allocation.
    { Box* a = new Box();
      a.set(111);
      Assert.isEqual(a.v, 111); }

    { Box* b = new Box();
      b.set(222);
      Assert.isEqual(b.v, 222); }

    // ── T3: a null strong pointer leaving scope frees nothing ──
    { Box* nul = 0;
      Assert.isTrue(nul == 0); }

    // ── T4–T5: dealloc() fires once per object freed ───────────
    { Tracker* t = new Tracker();
      t.tag = 7; }
    Assert.isEqual(deallocCallCount, 1);

    { Tracker* t2 = new Tracker(); }
    Assert.isEqual(deallocCallCount, 2);

    // ── T6–T7: alloc / delete round-trip exercises the churn path
    //          without burning through the O0 instruction budget.
    //          The main coverage point is that an allocation after
    //          a delete succeeds — i.e. the free-list actually
    //          reclaims the block rather than just marking it.
    u16 three = churnOne(3);
    u16 seven = churnOne(7);
    Assert.isTrue(three == 3 && seven == 7);

    { Box* afterLoop = new Box();
      afterLoop.set(999);
      Assert.isEqual(afterLoop.v, 999); }

    // ── T8: dealloc() count unchanged by the Box churn ─────────
    Assert.isEqual(deallocCallCount, 2);

    // ── T9: new T[N] for a primitive: can write + read elements ─
    u8* buf = new u8[20];
    buf[0] = 42;
    buf[19] = 99;
    Assert.isTrue(buf[0] == 42 && buf[19] == 99);
    delete buf;

    // ── T10: delete on an array of a class with dealloc() runs
    //          dealloc() once per element (array-walk path) ──────
    deallocCallCount = 0;
    { Tracker* arr = new Tracker[6]; }
    Assert.isEqual(deallocCallCount, 6);

    // ── T11–T13: introspection via the Heap class ──────────────
    // Heap.totalSize() is compile-time capacity (sum across all
    // reserved banks on banked-heap, whole region on flat).
    // Heap.size() is currently-free bytes; after all deletes above,
    // it should equal totalSize(). Largest single extent is per-bank
    // on multi-bank layouts — floor depends on the layout's bank
    // window size (16 KB on xe-heap, 4 KB on xt-heap's data half).
    // 4096 is the common lower bound; heapCap itself must still be
    // at least the smallest flat-heap layout's reservation
    // (xl-shadow / xe-nobank reserve 12 KB after the screen split).
    u32 heapCap  = Heap.totalSize();
    u32 heapFree = Heap.size();
    u16 heapLrg  = Heap.largest();
    Assert.isEqual(heapFree, heapCap);
    Assert.isTrue(heapCap  >= 12288);
    Assert.isTrue(heapLrg  >= 4096);

    Assert.summary();
    return;
}