// hfa_struct_return.xc — arm64 homogeneous float aggregate (HFA) ABI.
//
// A struct whose leaves are all the same float/double type, 1-4 of them (NSPoint
// = 2 doubles, NSRect = 4), is passed and returned in v-registers (d0..d3), NOT
// x0:x1 or an x8 sret. This is how Cocoa hands back `-frame`/`-bounds`. The arm64
// backend classifies HFAs and routes them through the FP register bank on every
// call path (Call / CallIndirect / VTblDispatch) and both callee sides. Values
// are read back through i32 so the check doesn't depend on %f formatting.
//xtc-flags: target=arm64
#import "Stdio.xc"
#import "Assert.xc"

struct Rect { double x; double y; double w; double h; }

Rect makeRect(double b) { Rect r; r.x = b; r.y = b + (double)1; r.w = b + (double)2; r.h = b + (double)3; return r; }
double sumRect(Rect r) { return r.x + r.y + r.w + r.h; }

void main(void) {
    Assert.reset();

    Rect r = makeRect((double)100);        // HFA return (callee v0-v3, caller reads v0-v3)
    Assert.isEqual((i32)r.x, 100);
    Assert.isEqual((i32)r.h, 103);

    Assert.isEqual((i32)sumRect(r), 406);  // HFA arg (caller passes v0-v3, callee reads v0-v3)

    // A locally built HFA round-trips too.
    Rect k; k.x = (double)1; k.y = (double)2; k.w = (double)3; k.h = (double)4;
    Assert.isEqual((i32)sumRect(k), 10);

    Assert.summary();
    return;
}
