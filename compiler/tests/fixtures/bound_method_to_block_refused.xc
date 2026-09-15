// bound_method_to_block_refused.xc — the OTHER direction, 0.5.
//
// block_to_bound_method_refused.xc pins `block -> ^`. This pins `^ -> block`,
// which was silently ACCEPTED: it compiled clean, the slot tested TRUE, and
// then the call did nothing at all. A callback that never fires is the button
// that does nothing — the same silent shape the sibling refusal exists to
// prevent, missed only because the check was written one-way.
//
// The refusal is permanent, not a placeholder: a block OWNS its captures and a
// callback never owns its receiver, so converting would either retain the
// receiver (closing a cycle) or produce a block with no owner. Non-goal,
// settled 2026-08-28 — private:docs/Design/bound-methods.md §7.
//xtc-flags: expect=sema-error
#use Stdio
class C { void m(i32 n) { Stdio.printf("m %d\n", n); } }
i32 main(void)
{
    C* c = new C();
    block b void(i32 n);
    b = &c.m;
    if (b) { b((i32)9); }
    return 0;
}
