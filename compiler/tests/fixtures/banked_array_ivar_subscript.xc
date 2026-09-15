// banked_array_ivar_subscript.xc — `:banked u8@` array stored in an
// ivar, accessed via subscript inside a method body.
//
// Pre-bug-fix the banked-subscript-store/load paths read the
// pointer's bytes via `LDA $80nn` (treating ivar-encoded
// 0x8000 | offset as an absolute address). For a class member
// `banked:u8@ data;` that always landed in screen RAM and the
// store/load went to the wrong place.
//
// A banked array of a NON-class element type: ARC never managed these,
// so `delete` on one is the only way to free it and is allowed outright
// (bug 026 retired -farc=off, which this used to need).

#import "Stdio.xc"
#import "Assert.xc"

class Buf
{
    banked:u8* data;
    u16 sz;

    void allocate(u16 n)
    {
        data = new u8[n];
        sz = n;
    }

    void put(u16 idx, u8 v)  { data[idx] = v; }
    u8   get(u16 idx)        { return data[idx]; }
}

void main(void)
{
    Assert.reset();
    Buf* b = new Buf();
    b.allocate(8);
    b.put(0, 42);
    b.put(7, 99);
    Assert.isEqual((u16)b.get(0), 42);   // T1
    Assert.isEqual((u16)b.get(7), 99);   // T2
    Assert.summary();
    return;
}
