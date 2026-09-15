// class_ivar_after_array.xc — an ivar declared AFTER an inline array ivar.
//
// The instance layout reserves the hidden vtable slot at field 0, and the front
// end hardcoded that slot at 2 bytes on every target. arm64 lays a pointer out
// as 8, so every object was allocated six bytes short of what the backend
// addresses — and the same number is the STRIDE `delete obj[]` walks. Allocator
// rounding hid it for every small class in the corpus: the shortfall landed in
// the block's padding and nothing noticed.
//
// It stops being hidden the moment an object is big enough that the last ivar
// sits past the rounded-up block. Here the array fills the block and `_n` falls
// off the end, so the NEXT allocation writes over it:
//
//   p = new Box(); p.set(111);
//   q = new Box(); q.set(222);
//   p.n() -> 1329725551      // q's header, read as p's field
//
// Found writing selfhost/lexer/BigNat.xc, whose whole job is to be a big object
// with a length beside it.
//
//   T1  the first object's trailing ivar survives a second allocation
//   T2  ...and the array's last element does too (the other side of the block)
//   T3  three live objects, all independent
//   T4  the same shape one element shorter — the case rounding used to cover

#import "Stdio.xc"
#import "Assert.xc"

class Box
{
    u32 _a[96];
    u32 _n;                       // the ivar that fell off the end
    void init(void) { _n = (u32)0; }
    void set(u32 v) { _n = v; _a[0] = v + (u32)1; _a[95] = v + (u32)2; }
    u32 n(void)     { return _n; }
    u32 first(void) { return _a[0]; }
    u32 last(void)  { return _a[95]; }
}

class Small
{
    u32 _a[7];
    u32 _n;
    void init(void) { _n = (u32)0; }
    void set(u32 v) { _n = v; _a[6] = v + (u32)2; }
    u32 n(void)    { return _n; }
    u32 last(void) { return _a[6]; }
}

void main(void)
{
    Box* p = new Box();  p.set((u32)111);
    Box* q = new Box();  q.set((u32)222);

    Assert.isEqual(p.n(), (u32)111);            // T1
    Assert.isEqual(q.n(), (u32)222);
    Assert.isEqual(p.last(), (u32)113);         // T2
    Assert.isEqual(q.last(), (u32)224);
    Assert.isEqual(p.first(), (u32)112);
    Assert.isEqual(q.first(), (u32)223);

    Box* r = new Box();  r.set((u32)333);       // T3
    Assert.isEqual(p.n(), (u32)111);
    Assert.isEqual(q.n(), (u32)222);
    Assert.isEqual(r.n(), (u32)333);

    Small* s1 = new Small(); s1.set((u32)7);    // T4
    Small* s2 = new Small(); s2.set((u32)9);
    Assert.isEqual(s1.n(), (u32)7);
    Assert.isEqual(s2.n(), (u32)9);
    Assert.isEqual(s1.last(), (u32)9);
    Assert.isEqual(s2.last(), (u32)11);

    Assert.summary();
}
