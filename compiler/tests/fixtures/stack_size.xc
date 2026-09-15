//xtc-flags: skip
// ^ corpus xt6502 runs with banked-heap layout (xt-heap, 192 KB),
//   so Heap.totalSize() > 12288 always — the fixture's premise
//   ("12288 bytes on xl-shadow / xe-nobank") doesn't hold here.
//   arm64 has host-malloc, also unbounded. The flag this test
//   exercises (--stack-size=N reclaim) isn't part of the corpus
//   pipeline either. Verify manually on a flat layout instead.
// stack_size.xc — --stack-size=N reclaims the unused stack/heap
// gap into the heap region on flat-heap targets.
//
// Without --stack-size the linker layout fixes the heap to its
// declared [heap] range (12288 bytes on xl-shadow / xe-nobank
// after the screen reservation at $8000-$9FFF). Passing a
// smaller stack ceiling via --stack-size=256 pulls stack_top down
// to stack_low+$100, then emits heap_low = stack_top so the heap
// absorbs every byte the stack no longer reserves.
//
// Compiled with --stack-size=256 (see run_fixtures.sh) and
// asserts Heap.totalSize() exceeds the layout default — a
// baseline compile (no flag) returns exactly 12288.

#import "Stdio.xc"
#import "Heap.xc"
#import "Assert.xc"

void main(void)
{
    // T1: Heap.totalSize() (u32) exceeds the 12288-byte layout
    // default. Under --stack-size=256 the heap reclaims roughly
    // 1.5 KB of the stack/heap gap.
    u32 cap = Heap.totalSize();
    Assert.isTrue(cap > 12288);

    // T2: Heap.size() (currently-free bytes, u32) equals
    // totalSize() on a freshly-booted heap that has no
    // outstanding allocations. Also verifies the rename:
    // size() used to mean totalSize() before the API change.
    u32 live = Heap.size();
    Assert.isEqual(live, cap);

    Assert.summary();
}
