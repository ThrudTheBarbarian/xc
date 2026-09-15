// arc_stack_member.xc — ARC assignment lowering for stack-instance
// member stores into strong-class-pointer fields.
//
// Under -farc, `stackObj.field = expr;` where stackObj is a stack
// class instance (bare `Foo obj;` declaration) and field is a
// strong class pointer goes through emitArcStackMemberStore:
// direct absolute addressing, no indirection through the base's
// pointer.
//
// Stack class instances are already zero-init'd by the existing
// stack-instance codegen, so the first member store's release-
// old step sees null (no-op) rather than garbage.
//
// Test surface:
//   T1  Stack-instance's strong-pointer field is null after decl;
//       first store of `new T()` transfers the +1 cleanly.
//   T2  Reassignment with new releases the old instance.
//   T3  Reassignment with borrowed identifier retains the source.
//   T4  Reassignment with null releases the current.

#import "Stdio.xc"
#import "Assert.xc"

class Inner
{
    u8 mark;
    void dealloc(void) { innerDeallocs = innerDeallocs + $0A; }
}

class Container
{
    Inner* held;
}

u16 innerDeallocs;

void main(void)
{
    Assert.reset();
    innerDeallocs = $D0;                  // distinctive base (208)

    // Stack instance — zero-init'd by the stack-class codegen.
    Container c;

    // ── T1: first store (old was null) ──
    c.held = new Inner();
    c.held.mark = 1;
    Assert.isEqual(innerDeallocs, $D0);    // T1 — nothing freed yet

    // ── T2: reassign with new — old Inner released ──
    c.held = new Inner();
    c.held.mark = 2;
    Assert.isEqual(innerDeallocs, $DA);    // T2 — one Inner freed (+$0A)

    // ── T3: reassign with borrowed identifier ──
    Inner* src = new Inner();
    src.mark = 77;
    c.held = src;             // retain src; release previous Inner
    Assert.isEqual(innerDeallocs, $E4);    // T3 — two freed
    Assert.isEqual(c.held.mark, 77);

    // ── T4: reassign with null ──
    c.held = (Inner*)0;       // release src (field's +1); src still live via local
    Assert.isEqual(innerDeallocs, $E4);   // src survives; held's +1 released

    Assert.summary();
    return;
}
