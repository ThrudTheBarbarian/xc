#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

// Inter-procedural elision of a method's redundant self-retain/release bracket.
//
// ARC lowering puts `Retain(self)` at a method's entry and `Release(self)`
// before each return. That bracket protects `self` from being freed *during*
// the method (a borrowed receiver whose body drops its last reference — see
// arc_self_retain). It is redundant exactly when the method is ARC-inert: its
// body (excluding the bracket itself) performs no `Release`, no virtual
// dispatch, and calls only other inert functions (no external/runtime calls
// whose effect is unknown). An inert method cannot drop any refcount to zero,
// so `self` survives and the bracket is a no-op. Inertness is computed as a
// backward call-graph fixpoint, so a delegating accessor (asI16 → asI32) is
// inert iff its inert callee is, and a method reaching a releasing free
// function (observeSelfAlive → release_holder) is correctly kept.
//
// The bracket is identified conservatively: a method (name carries `$`) whose
// FIRST entry instruction is `Retain(receiver-param)` with exactly that one
// Retain of the receiver — so a strong-local copy `Foo@ a = self/param` (an
// extra, non-first retain) is left alone. -O2+, before inlining.
@interface XTIROptArcSelfRetain : NSObject <XTIROptPass>
@end

NS_ASSUME_NONNULL_END
