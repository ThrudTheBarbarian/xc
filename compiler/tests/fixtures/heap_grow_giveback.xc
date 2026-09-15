// heap_grow_giveback.xc — exercises the on-demand banked heap
// (xt6502 `[heap] bank = true`): allocating past one 12 KB data bank
// claims a second on demand, and freeing everything returns the grown
// bank to the shared bank bitmap so the whole heap is free again.
// xt6502-only: the on-demand banked heap is an xt-hardware feature.
#import "Stdio.xc"
#import "Heap.xc"

class Big { u8 data[6000]; }

u8 grow(void)
{
    // 3 x ~6 KB (~18 KB) cannot fit one 12 KB bank — the heap must claim
    // a second. ARC releases all three at scope exit, emptying it.
    Big* a = new Big();
    Big* b = new Big();
    Big* c = new Big();
    a.data[0] = 1;
    b.data[5999] = 2;     // touch the far end of the last (grown) bank
    c.data[0] = 3;
    u8 ok = (a != (Big*)0 && b != (Big*)0 && c != (Big*)0) ? 1 : 0;
    return ok;
}

i32 main(void)
{
    u32 cap = Heap.totalSize();
    u8 grew = grow();              // 1 ⇒ all three allocations succeeded
    u32 freeAfter = Heap.size();   // == cap ⇒ grown bank was given back
    u8 returned = (freeAfter == cap) ? 1 : 0;
    Stdio.printf("grew=%u returned=%u\n", grew, returned);
    return 0;
}
