// heap_cross_bank.xc — multi-bank allocator + cross-bank read/write
//
// heap_multibank exercises a single banked-pointer in isolation: each
// pointer's writes are read back by the same pointer, so a misrouted
// bank store + matching misrouted bank read still round-trip
// consistently. That mask hid two bugs simultaneously:
//
//   (1) _banked_load/store_byte and _method_call_tramp wrote the
//       bank byte to $82 (code reg) instead of $83 (data reg).
//   (2) `new T()` stored heap_bank_first into slot+2 regardless of
//       which bank the allocator actually placed the object in.
//
// Both bugs were silent because every banked-pointer access ended up
// in the same physical bank (heap_bank_first). This fixture forces
// two distinct banks to hold distinct values and cross-reads — if
// either bug regresses the cross-read returns the other bank's value.
//
// Test surface:
//   T1  s1.marker round-trip — proves single-bank case still works
//   T2  s2.marker (other bank) cross-read returns its OWN value
//   T3  walk an array of banked pointers spanning both banks; each
//       element retains its bank-local marker

#import "Stdio.xc"
#import "Assert.xc"

class Slot { u16 marker; }

void main(void)
{
    Assert.reset();

    // Fill bank 1 (4096 bytes incl. 4-byte header).
    u8* filler = new u8[4092];

    // s2 lands in bank 2 (bank 1 exhausted).
    banked:Slot* s2 = new Slot();
    s2.marker = $CAFE;

    // Free bank 1, s1 lands back in bank 1.
    delete filler;
    banked:Slot* s1 = new Slot();
    s1.marker = $BEEF;

    // T1: bank 1 read returns bank 1 value.
    Assert.isEqual(s1.marker, $BEEF);

    // T2: cross-bank read — s2 is in bank 2, must return $CAFE
    // even though s1's most-recent write was to bank 1 at the
    // same offset within the bank window.
    Assert.isEqual(s2.marker, $CAFE);

    // T3: distinct three-way. Allocate s3 by filling bank 2, freeing
    // s2's slot doesn't free much (only 11 bytes), so s3 should land
    // in bank 2's larger remaining free region. Fill bank 2 with
    // another large filler to force s3 into bank 3+.
    u8* filler2 = new u8[4060];   // most of bank 2's remaining space
    banked:Slot* s3 = new Slot();
    s3.marker = $1234;

    // s1 and s2 still hold their values; s3 is fresh.
    Assert.isEqual(s1.marker, $BEEF);
    Assert.isEqual(s2.marker, $CAFE);
    Assert.isEqual(s3.marker, $1234);

    Stdio.printf("s1=%u s2=%u s3=%u\n", s1.marker, s2.marker, s3.marker);

    s1 = 0;                  // ARC releases each class instance on the store
    s2 = 0;
    s3 = 0;
    delete filler2;          // a primitive array: `delete` is still its only free

    Assert.summary();
    return;
}
