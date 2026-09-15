// arc_pure_read_param.xc — 2e pure-read param peephole.
//
// The dead-param peephole (shipped) elides the callee-retains-
// params entry retain + scope-exit decref when the param name
// never appears in the body. This fixture exercises the next
// relaxation: elide those too when the param appears but only
// in read-only positions.
//
// Safety sketch: under always-+1 + callee-retains-params applied
// recursively, the caller's caller holds a live +1 on the
// pointee for the entire duration of this call. As long as our
// own slot never rebinds — no `p = x`, no `&p`, no `delete p`,
// no tuple-LHS rebind — the pointee stays alive without our own
// +1. Scope-exit has nothing to release since we never
// registered.
//
// Disqualifying shapes, checked in arcNodeHasNoEscapingUseOfName:
//   • XTAssignExprNode with identifier(name) LHS
//   • XTUnaryExprNode(addrOf) on identifier(name)
//   • XTDeleteNode with identifier(name) operand
//   • XTTupleAssignNode target identifier(name)
//   • Any XTAsmBlockNode anywhere in the body (conservative —
//     asm might write to the slot via its ZP address)
//
// Safe shapes that keep the peephole active:
//   • Field / method receiver: p.field, p.method()
//   • Arrow projection: p->field (even chained: a.b.c)
//   • Arg to another function: f(p) — callee does its own retain
//   • Comparisons / arithmetic on class ptrs: p == q
//   • Cast, ternary operand
//   • Return expression: return p — the return-retain fires
//     independently of our slot
//
// T1-T2: pure-read field access, dealloc count stable.
// T3-T4: pure-read arg pass, dealloc count stable.
// T5-T6: pure-read comparison, dealloc count stable.
// T7-T8: rebinding keeps the retain correct (new Item dealloced
//        at scope exit; original param untouched).
// T9-T10: pure-read return — return-retain still fires.

#import "Stdio.xc"
#import "Assert.xc"

u16 itemDealloc;

class Item
{
    u8 id;
    u8 value;
    void dealloc(void) { itemDealloc = itemDealloc + 1; }
}

// Pure-read: only reads p's fields.
u8 readField(Item* p)
{
    return p.value;
}

// Pure-read: p as arg to another fn (callee-retains there).
u16 countId(Item* p)
{
    return (u16)p.id;
}

// Pure-read: comparison + return.
bool sameItem(Item* a, Item* b)
{
    return a == b;
}

// NOT pure-read: rebinds p. Keeps retain.
u16 swapInput(Item* p)
{
    p = new Item();
    return (u16)p.id;
}

// Pure-read: returns param. Return-retain fires independently.
Item* identityFn(Item* p)
{
    return p;
}

void main(void)
{
    Assert.reset();
    itemDealloc = 0;

    Item* a = new Item();
    a.id = 7;
    a.value = 42;

    // ── T1-T2: pure-read field access ──────────────────────
    u8 v = readField(a);
    Assert.isEqual((u16)v, 42);                           // T1
    Assert.isEqual(itemDealloc, 0);                       // T2

    // ── T3-T4: pure-read arg pass ──────────────────────────
    u16 id = countId(a);
    Assert.isEqual(id, 7);                                // T3
    Assert.isEqual(itemDealloc, 0);                       // T4

    // ── T5-T6: pure-read compare ───────────────────────────
    Item* b = a;
    bool same = sameItem(a, b);
    Assert.isTrue(same);                                  // T5
    Assert.isEqual(itemDealloc, 0);                       // T6

    // ── T7-T8: rebind keeps the retain ─────────────────────
    // swapInput entry retains a (rc 1→2). p=new Item releases
    // old a (rc 2→1, no dealloc) and stores new Item (rc 1).
    // Scope exit releases the new Item (rc 1→0, dealloc).
    u16 sid = swapInput(a);
    Assert.isEqual(sid, 0);                               // T7
    Assert.isEqual(itemDealloc, 1);                       // T8

    // ── T9-T10: pure-read with return — return-retain fires ─
    {
        Item* c = identityFn(a);
        // a and c both alive, rc=2.
        Assert.isEqual((u16)c.id, 7);                     // T9
    }
    // c scope-exited; rc 2→1. a still alive. No new dealloc.
    Assert.isEqual(itemDealloc, 1);                       // T10

    Assert.summary();
    return;
}
