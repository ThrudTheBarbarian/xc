// block_to_bound_method_refused.xc — uxkit/030.
//
// A block is a class reference (it desugars to `Blk$<sig>*`); a `^` is a
// two-word (receiver, code) pair. Storing one in the other used to type-check
// and then fail in two different SILENT ways: the slot read back FALSE and the
// call never happened, or it read TRUE and the call took SIGBUS inside the
// callee. Neither said anything.
//
// The refusal is PERMANENT, and this comment used to say the opposite: that
// "the unification is planned" and that when it landed, this fixture should
// compile and print "truthy" rather than be refused. That was an acceptance
// gate pointing the wrong way.
//
// Settled 2026-08-28 (private:docs/Design/bound-methods.md §7): a block OWNS its
// captures; a callback never owns its receiver and auto-zeroes when stored.
// Unifying them would either retain the receiver — closing exactly the cycles
// §6 rejects — or make `block` mean two different lifetimes depending on how it
// was built. The two types stay distinct BECAUSE the type is the ownership
// contract an API states.
//
// So this direction stays a refusal, and a diagnostic at the assignment is
// still worth more than a crash at the call.
//xtc-flags: expect=sema-error
#import "Stdio.xc"
typedef void act_t(i32);
void main(void)
    {
    auto a = block void(i32 s) { Stdio.printf("fired %ld\n", s); };
    act_t^ f = a;
    if (f) { Stdio.printf("truthy\n"); }
    }
