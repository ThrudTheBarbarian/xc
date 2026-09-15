// proto_dispatch_arg_width.xc — regression for private:docs/bugs/013 (FIXED).
//
// A protocol-typed dispatch (`p.m(narrowLiteral)`) must widen a narrow argument
// to the callee's parameter type, exactly as the direct-call and implicit-self
// paths do. The explicit-receiver PROTOCOL path (XTIRLowering, the
// `node.resolvedVirtualSlot != nil` branch feeding emitProtoDispatch/
// emitVTblDispatch) pushed each arg at its own natural IR width, so on xt6502 a
// bare `5` (16-bit) reached an `i32` param as 2 bytes where the callee reads 4 —
// the high half was stale and `seed + x` came back as garbage (268248425). The
// wide-register backends (arm64/x86_64/arm9/m68k) masked it. The sibling bug 009
// fixed the IMPLICIT-self path; this was the third dispatch path it left
// uncovered. Fix: `coerceArgs:toProtocolMethodOf:` widens each arg to the
// protocol method's declared param type (read from a new protocol-decl registry
// in the lowering) before dispatch.

#import "Stdio.xc"
#import "Assert.xc"

protocol Pingable { i32 ping(i32 x); }

class Widget : Object <Pingable>
{
    i32 seed;
    void init(void) { seed = 100; }
    i32 ping(i32 x) { return seed + x; }
}

void main(void)
{
    Assert.reset();

    Widget* w = new Widget();
    Pingable* p = (Pingable*)w;

    Assert.isEqual(p.ping(5), 105);   // bare literal through protocol dispatch
    Assert.isEqual(p.ping(20), 120);

    Assert.summary();
    return;
}
