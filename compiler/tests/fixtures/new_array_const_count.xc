// new_array_const_count.xc — `new T[N]` with a small u8-literal element
// count must allocate a real (non-null) buffer. Regression test for the
// count being marshalled as a single byte (uninitialised count-hi byte →
// garbage allocation size → OOM → null buffer); the lowering now widens
// the count to u16 before the allocator call.
//
//   T1   new pointer[16] returns a usable buffer; a written value
//        round-trips through a high index.
//   T2   new u8[40] round-trips a byte at a high index.

#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    Assert.reset();

    pointer* p = new pointer[16];
    p[15] = (pointer)$1234;
    Assert.isTrue(p[15] == (pointer)$1234);     // T1

    u8* b = new u8[40];
    b[39] = (u8)200;
    Assert.isEqual((u16)b[39], (u16)200);        // T2

    Assert.summary();
    return;
}
