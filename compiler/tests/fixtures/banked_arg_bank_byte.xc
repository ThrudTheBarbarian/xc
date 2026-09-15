// banked_arg_bank_byte.xc — passing a `banked:T@` as a function
// argument must deliver all three bytes of the pointer (lo, hi,
// bank). The caller's arg-push stores A to slot+0, X to slot+1,
// Y to slot+2 — but several read paths only produced lo/hi and
// left Y holding stale caller state, so the callee dereferenced
// the wrong 16 KB page and `(p),Y` read garbage.
//
// T1  Identifier source — sanity baseline (this case always
//     worked via the `paramWidth == 3` identifier special-case).
// T2  Forwarding a banked param to another banked-param callee
//     (param → param) — also via the identifier path but inside
//     a banked helper.
// T3  Subscript source — `arr[0]` on a stack array of
//     `banked:T@`. The constant-index array read used to emit
//     only A=lo / X=hi and rely on the caller-push's `TYA` for
//     the bank byte; Y was whatever the caller-save had left.
// T4  Member-access source — `h.leaf` where `leaf` is a
//     `banked:T@` ivar. Banked-heap field reads went through
//     `_banked_load_byte` for bytes 0 and 1 but never byte 2.
//
// Running: xt-heap / xe-heap only. On flat targets `banked:`
// still parses but collapses — doesn't exercise the bug.

#import "Stdio.xc"
#import "Assert.xc"

class Leaf
{
    u8 id;
    void dealloc(void) { }
}

class Holder
{
    banked:Leaf* leaf;
    void dealloc(void) { }
}

u8 peek(banked:Leaf* p)
{
    return p.id;
}

u8 forward(banked:Leaf* p)
{
    return peek(p);
}

void main(void)
{
    Assert.reset();

    // T1: identifier source
    banked:Leaf* a = new Leaf();
    a.id = 11;
    Assert.isEqual(peek(a), 11);

    // T2: forwarding a banked param
    Assert.isEqual(forward(a), 11);

    // T3: subscript source (constant index) — stack array of banked:Leaf@
    banked:Leaf* arr[2];
    arr[0] = new Leaf();
    arr[0].id = 22;
    arr[1] = new Leaf();
    arr[1].id = 44;
    Assert.isEqual(peek(arr[0]), 22);
    Assert.isEqual(peek(arr[1]), 44);

    // T4: member-access source — banked:T@ ivar on a heap class
    Holder* h = new Holder();
    h.leaf = new Leaf();
    h.leaf.id = 33;
    Assert.isEqual(peek(h.leaf), 33);

    // T5: subscript source (dynamic index) — the i*3 path. Each
    // element is 3 bytes, so the scale multiplier is not a simple
    // shift.
    u8 i;
    i = 0;
    Assert.isEqual(peek(arr[i]), 22);
    i = 1;
    Assert.isEqual(peek(arr[i]), 44);

    Assert.summary();
    return;
}
