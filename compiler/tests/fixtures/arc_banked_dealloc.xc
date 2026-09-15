// arc_banked_dealloc.xc — Phase 4.2 Bug 3 (+ followon):
// scope-exit dealloc loop bank-wrap on banked-heap targets.
//
// Three stacked issues, all fixed:
//
//   • Block-size header read used `LDA (zpTmp),Y` direct. On
//     banked heap the header lives in the heap bank but the
//     caller's bank had been restored by _obj_decref's exit,
//     so the read pulled garbage. A size-hi byte with bit 7
//     set (free flag) would mask to 0 after AND #$7F, the loop-
//     end address would equal loop-start, and the body kept
//     re-iterating. Fixed by routing the two header-byte reads
//     through _banked_load_byte via _bankedPtrScratch.
//
//   • Direct `JSR _cls_X_dealloc` from a banked caller. The
//     banked window must show the object's bank when the method
//     runs (its (self),Y accesses go through the window). But
//     emitting `STA $82` inline from a banked caller swaps the
//     caller's own code page out from under the instruction
//     fetcher. Fixed with a non-banked trampoline
//     _arc_dealloc_tramp in main-code memory: save $82, select
//     object's bank, indirect-JMP to the method, restore $82
//     on return.
//
//   • `JSR _heap_free` at the end of the scope-exit walker was
//     only passing `LDY _heap_free_bank` for full banked 3-byte
//     pointers. Heap-placement pointers (the default on banked-
//     heap) skipped that setup, so _heap_free ran with Y =
//     whatever junk happened to be in the register — wrote the
//     free-flag to the wrong bank, silently corrupted the free-
//     list for the next allocation. Symptom was the allocator
//     looping forever on a size-0 block during the second alloc.
//     Fixed by extending the Y-load gate to also fire for the
//     isHeapImplicitBank case.
//
// Coverage:
//   T1-T3: single alloc + scope-exit-dealloc, repeated three
//           times. Exercises the full decref → dealloc loop →
//           _arc_dealloc_tramp → user dealloc → _heap_free cycle
//           on each call. Pre-fix the second call hung in the
//           allocator.

#import "Stdio.xc"
#import "Assert.xc"

u16 deallocCount;

class Item
{
    u8 id;
    void dealloc(void) { deallocCount = deallocCount + 1; }
}

void allocAndDrop(u8 id)
{
    Item* p = new Item();
    p.id = id;
    return;
}

void main(void)
{
    Assert.reset();
    deallocCount = 0;

    allocAndDrop(1);
    Assert.isEqual(deallocCount, 1);                    // T1

    allocAndDrop(2);
    Assert.isEqual(deallocCount, 2);                    // T2

    allocAndDrop(3);
    Assert.isEqual(deallocCount, 3);                    // T3

    Assert.summary();
    return;
}
