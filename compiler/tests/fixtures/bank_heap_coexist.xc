// bank_heap_coexist.xc — bank() and the on-demand heap share the data
//xtc-na: wasm32 — banked heap regions are a 6502 banking concept with no wasm meaning
// banks through one bitmap and never collide: bank() reserves a high
// data bank, the heap claims low banks as it grows, and the reserved
// bank's contents survive. xt6502-only (banked data heap is xt).
#import "Stdio.xc"
#import "Heap.xc"

class Big { u8 data[6000]; }

i32 main(void)
{
    // Reserve a dedicated high data bank.
    u8* dedicated = bank(BANK_DATA, 200);
    dedicated[0]    = 77;
    dedicated[5999] = 88;
    // Grow the heap across several banks (it claims low, skipping bank 200).
    Big* a = new Big();
    Big* b = new Big();
    Big* c = new Big();
    a.data[0] = 1;
    b.data[0] = 2;
    c.data[0] = 3;
    // The dedicated bank is untouched by the heap.
    u8 ok = (dedicated[0] == 77 && dedicated[5999] == 88) ? 1 : 0;
    Stdio.printf("ok=%u\n", ok);
    return 0;
}
