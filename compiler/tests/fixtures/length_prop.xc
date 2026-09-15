// length_prop.xc — .length pseudo-property on arrays and heap pointers.
//
// Covers:
//   T1  .length on a local fixed-size u8 array (compile-time constant)
//   T2  .length on a local fixed-size u16 array (compile-time constant)
//   T3  .length on a heap u8[] allocation (runtime header read)
//   T4  .length on a heap u16[] allocation (runtime, /2 divide)
//   T5  .length on a heap u32[] allocation (runtime, /4 divide)
//   T6  `for (T val in heapPtr)` iterates .length times
//   T7  .length reflects the actual requested count, not a rounded size

#import <Stdio.xc>
#import <Assert.xc>

void main(void) {
    Assert.reset();

    u8 localU8[10];
    Assert.isEqual(localU8.length, (u16)10);

    u16 localU16[7];
    Assert.isEqual(localU16.length, (u16)7);

    u8* hU8 = new u8[20];
    Assert.isEqual(hU8.length, (u16)20);
    delete hU8;

    u16* hU16 = new u16[16];
    Assert.isEqual(hU16.length, (u16)16);
    delete hU16;

    u32* hU32 = new u32[8];
    Assert.isEqual(hU32.length, (u16)8);
    delete hU32;

    // T6: for-in runs .length times on a heap pointer.
    u16* buf = new u16[5];
    buf[0] = 100; buf[1] = 101; buf[2] = 102; buf[3] = 103; buf[4] = 104;
    u16 count = (u16)0;
    for (u16 v in buf) {
        count = count + (u16)1;
    }
    Assert.isEqual(count, (u16)5);
    delete buf;

    // T7: exercising a few non-power-of-2 counts.
    u8* h17 = new u8[17];
    Assert.isEqual(h17.length, (u16)17);
    delete h17;

    Assert.summary();
}
