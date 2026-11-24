// `.length` takes its type from where it is used (#321). On the 64-bit
// targets it is u64 unless the destination is 32 bits or narrower, where it is
// the checked u32 form; a call resolves with it as u32, so an overload set
// picks what it always did. Elsewhere it is u32 (u16 on m68k) throughout, and
// the output is the same.
//xtc-na: xt6502 — the 6502 heap stores no element count, so a run-time `new T[n]` has no .length
#import "Stdio.xc"

void pick(u32 n) { Stdio.printf("pick(u32) %u\n", n); }
void pick(u64 n) { Stdio.printf("pick(u64) %llu\n", n); }
void wide(u64 n) { Stdio.printf("wide(u64) %llu\n", n); }
void narrow(u16 n) { Stdio.printf("narrow(u16) %u\n", (u32)n); }

u32 asU32(u8* p) { return p.length; }
u64 asU64(u8* p) { return p.length; }
u64 count(void) { return (u64)7000; }

i32 main(void)
{
    u8 fixed[12];
    u8* heap = new u8[count()];
    pick(fixed.length);
    pick(heap.length);
    wide(heap.length);
    narrow(fixed.length);
    u32 a = heap.length;
    u64 b = heap.length;
    u16 c = fixed.length;
    Stdio.printf("u32 %u, u64 %llu, u16 %u\n", a, b, (u32)c);
    Stdio.printf("returned %u %llu, cast %u\n", asU32(heap), asU64(heap), (u32)heap.length);
    u64 sum = (u64)0;
    for (u8 v in heap)
        sum = sum + (u64)1;
    Stdio.printf("for-in %llu, arithmetic %llu\n", sum, heap.length - (u64)1);
    delete heap;
    return 0;
}
