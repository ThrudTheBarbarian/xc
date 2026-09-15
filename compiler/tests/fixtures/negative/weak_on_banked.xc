// weak_on_banked.xc — `weak:banked:T@` in a class ivar is rejected
// on FLAT targets. Banked-heap targets (xt-heap / xe-heap) now
// accept this shape as of PR 9; the fixture compiles with -m xl
// (flat), where the annotation is meaningless and sema still
// objects.
//
// xtc: error "`weak:` on banked:T@ is not yet supported in this position (class ivars"

class Leaf { u8 v; }

class Holder {
    weak:banked:Leaf* back;
}

u8 main() {
    return (u8)0;
}
