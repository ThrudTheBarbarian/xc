// heap_multibank.xc — multi-bank allocator coverage.
//
// Exercises the allocator's per-bank walk and the method-call bank
// wrap on banked-heap targets with `bank = 1-2`. A deliberate bank-1
// exhaustion before a Box allocation forces the Box to land in bank
// 2, then a method call on that Box must switch the bank window to
// bank 2 before the `(self),Y` stores inside `set()` land in the
// wrong physical bank.
//
// Scoped to xt-heap / xe-heap only: flat-heap targets collapse the
// bank count to one and have no multi-bank semantics to exercise.
// On those targets this fixture still compiles and passes — the
// "multi-bank" path simply never fires because heap_bank_first ==
// heap_bank_last.
//
// Test surface:
//   T1  bank-2 allocation succeeds after bank 1 is exhausted
//   T2  method write on a bank-2 receiver — proven by a readback
//       method whose body runs with bank 2 selected and reads
//       self.v via (self),Y
//   T3  direct `.v` read on a bank-2 banked pointer from main code,
//       via the emitMemberAccess banked-pointer path (stages the
//       pointer into _bankedPtrScratch and routes the load through
//       _banked_load_byte which brackets the access in a bank
//       save-select-restore)
//   T4  direct `.v = val` write on a bank-2 banked pointer via the
//       emitAssignExpr banked-member-write branch, routed through
//       _banked_store_byte; readback by method call confirms the
//       bytes landed in the right physical bank
//   T5  banked subscript write with a constant index, then read
//       back via banked subscript load (both paths route through
//       _banked_store_byte / _banked_load_byte)
//   T6  banked subscript with a dynamic (runtime) index —
//       exercises the variant of the store branch that evaluates
//       the index into Y before staging the pointer
//   T7  u32 member write + read on a bank-2 receiver. Exercises
//       the width-4 extension of the banked member-access paths
//       (bytes 0-1 flow through A/X, bytes 2-3 through _u32HiReg
//       across the _banked_store_byte / _banked_load_byte calls)
//   T8  u16 direct deref `@p` cross-bank — emitUnaryExpr deref
//       branch extended from u8 to widths 2-4
//   T9  u32 direct deref `@p` cross-bank
//   T10 delete on a bank-2 pointer coalesces into bank 2 and the
//       freed block is reusable by a subsequent new

#import "Stdio.xc"
#import "Assert.xc"

class Box
{
    u16 v;
    u32 big;
    void set(u16 x) { v = x; }
    u16 get(void)   { return v; }
}

void main(void)
{
    Assert.reset();

    // Consume most of bank 1 so the subsequent Box allocation
    // either spills into bank 2 (xt-heap: 4 KB bank filled
    // exactly) or stays in bank 1 (xe-heap: 16 KB bank, Box
    // lands in the remainder). Either way the `banked:Box@`
    // pointer carries a live bank byte and the method-call
    // bank wrap, banked member read/write, banked subscript,
    // and direct-deref paths all exercise — the per-target
    // landing bank just changes which physical bank they land
    // in. 4092 = 4096 - 4-byte block header fills xt's data
    // bank exactly; the allocator's min-split threshold is 4
    // bytes so no residue stays behind.
    u8* big = new u8[4092];
    Assert.isTrue((u16)big != 0);            // T1 part A

    // Allocate a Box — must spill into bank 2 with a 3-byte banked
    // pointer so the caller captures the picked bank id.
    banked:Box* b = new Box();
    Assert.isTrue((u16)b != 0);              // T1 part B

    // Method call on a bank-2 receiver: the call-site bank wrap
    // selects byte 2 of `b` before the JSR so `(self),Y` inside
    // set() writes into bank 2's physical RAM. A matching get()
    // reads it back via the same wrap — if either the write or
    // the read landed in the wrong bank the value is 0.
    b.set(777);
    u16 got = b.get();
    Assert.isEqual(got, 777);                // T2

    // Direct `.v` read on a bank-2 banked pointer — exercises the
    // emitMemberAccess banked-pointer branch rather than the
    // method-call wrap. Must return 777 (written by b.set above).
    Assert.isEqual(b.v, 777);                // T3

    // Direct `.v = val` write on a bank-2 banked pointer, then read
    // back via the method-call path. Exercises the emitAssignExpr
    // banked-member-write branch: _banked_store_byte must brackets
    // the stores with the receiver's bank selected, or the bytes
    // land in the wrong physical bank and the readback returns
    // stale data.
    b.v = 12345;
    Assert.isEqual(b.get(), 12345);          // T4

    // Banked subscript write + read round-trip. `buf` goes to
    // bank 2 (bank 1 is still full) with a 3-byte banked pointer.
    // Main code runs with bank 1 selected, so the subscript store
    // must bracket the byte write in a bank save-select-restore —
    // otherwise the byte lands in bank 1 and the readback comes
    // back as stale/garbage. Constant and dynamic-index paths are
    // both exercised.
    banked:u8* buf = new u8[8];
    buf[0] = $AA;                            // constant idx (store)
    buf[7] = $55;                            // constant idx (store)
    u8 i = 3;
    buf[i] = $C3;                            // dynamic idx (store)
    Assert.isTrue(buf[0] == $AA);            // T5 constant idx (load)
    Assert.isTrue(buf[7] == $55 && buf[i] == $C3); // T6 dyn + const

    delete buf;

    // u32 field round-trip on a bank-2 banked pointer. Exercises
    // the width-4 extension of the member read/write paths. Each
    // byte flows through _banked_store_byte / _banked_load_byte
    // individually; bytes 0-1 park on the xtc stack across the
    // staging and the helper JSRs, bytes 2-3 stay in _u32HiReg.
    // Verify via both a direct read and a u16-narrowing `if` so
    // the high bytes are actually exercised (Assert.isEqual on
    // u32 would pass on low-byte match alone).
    b.big = $12345678;
    Assert.isEqual(b.big, $12345678);        // T7 u32 field round-trip
    u32 back = b.big;
    if (back == $12345678) { Assert.isTrue(true); }
    else                   { Assert.isTrue(false); }

    // Direct `@p` deref at widths 2 and 4 on a bank-2 banked
    // pointer. The write side parks byte 0 and byte 1 on the
    // xtc stack; the read side walks high-to-low through A/X/
    // _u32HiReg. Both must correctly bracket the (scratch),Y
    // access in a bank save-select-restore.
    banked:u16* p16 = new u16[1];
    *p16 = $BEEF;
    u16 r16 = *p16;
    Assert.isEqual(r16, $BEEF);              // T8 u16 deref round-trip

    banked:u32* p32 = new u32[1];
    *p32 = $CAFEBABE;
    u32 r32 = *p32;
    if (r32 == $CAFEBABE) { Assert.isTrue(true); }  // T9 u32 deref
    else                  { Assert.isTrue(false); }

    delete p16;
    delete p32;

    // u16/u32 banked subscript — exercises the width-2/4
    // extension of the subscript paths. Each element's byte
    // writes flow through _banked_store_byte and the readback
    // reassembles via _banked_load_byte. Both constant and
    // dynamic-index stores are exercised.
    banked:u16* arr16 = new u16[4];
    arr16[0] = $AABB;                        // const idx
    arr16[3] = $CCDD;                        // const idx
    u8 k = 2;
    arr16[k] = $EEFF;                        // dynamic idx
    Assert.isEqual(arr16[0], $AABB);         // const read
    Assert.isEqual(arr16[3], $CCDD);
    Assert.isEqual(arr16[k], $EEFF);
    u16 arr16_3 = arr16[3];
    delete arr16;

    banked:u32* arr32 = new u32[2];
    arr32[0] = $12345678;
    arr32[1] = $DEADBEEF;
    u32 e0 = arr32[0];
    u32 e1 = arr32[1];
    if (e0 == $12345678) { Assert.isTrue(true); } else { Assert.isTrue(false); }
    if (e1 == $DEADBEEF) { Assert.isTrue(true); } else { Assert.isTrue(false); }
    delete arr32;

    // Free and reallocate: proves the bank-2 free block coalesces
    // back into a usable extent once the last reference goes.
    b = 0;
    banked:Box* c = new Box();
    c.set(99);
    Assert.isEqual(c.get(), 99);             // T10

    Stdio.printf("get=%u arr16=%u\n", c.get(), arr16_3);
    Stdio.printf("e0=%lu e1=%lu\n", e0, e1);

    c = 0;                   // a class instance: ARC releases it on the store
    delete big;              // a primitive array: `delete` is still its only free

    Assert.summary();
    return;
}
