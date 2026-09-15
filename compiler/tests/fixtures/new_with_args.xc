// new_with_args.xc — `new T(a, b, …)` passes constructor args
// to init() via the regular hw-stack push convention.
//
// Pre-fix, emitNewExpr emitted `JSR _heap_alloc / stamp class-id /
// JSR _cls_T_init` without pushing the user-supplied args first,
// so init's prologue PLAs read whatever happened to be left under
// the return address. The fix stashes the heap pointer in a
// 2-byte static slot (_new_init_ptr) before pushing args, then
// restores after init returns — the args go on the hw stack
// where the callee's prologue expects them.
//
// Coverage:
//   T1: single u16 arg. Verifies the arg actually arrives.
//   T2-T4: u16 + u8 + i16 mix; signed negative argument tests
//       width-aware sign-extension on the push side.
//   T5: zero-arg `new T()` still works (the no-arg branch keeps
//       the old PHA-save shape — fix shouldn't regress it).
//
// (u32 ivar assignment is silently 16-bit-truncated by an
// unrelated pre-existing bug — not exercised here.)

#import "Stdio.xc"
#import "Assert.xc"

class P1 {
    u16 v;
    void init(u16 x) { v = x; return; }
}

class P3 {
    u16 a;
    u8  b;
    i16 c;
    void init(u16 a0, u8 b0, i16 c0) {
        a = a0;
        b = b0;
        c = c0;
        return;
    }
}

class P0 {
    u16 z;
    void init(void) { z = 7777; return; }
}

void main(void)
{
    Assert.reset();

    P1* p1 = new P1(1234);
    Assert.isEqual(p1.v, 1234);

    P3* p3 = new P3(50000, 99, -50);
    Assert.isEqual(p3.a, 50000);
    Assert.isEqual(p3.b, 99);
    Assert.isEqual(p3.c, (i16)-50);

    P0* p0 = new P0();
    Assert.isEqual(p0.z, 7777);

    Assert.summary();
    return;
}
