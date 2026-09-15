#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

NS_ASSUME_NONNULL_BEGIN

// Dead-function-elimination pass.
//
// Walks the call graph from the module's entry points (main, plus any
// function symbol whose `escapes` flag is set, plus every vtable
// entry's target) and removes functions that aren't reachable.
//
// Conservative: any `CallIndirect` / `CallBankedIndirect` /
// `VTblDispatch` site we don't statically resolve is treated as
// "calls everything in its possible target set". For vtables we have
// the resolved targets; for raw function pointers we keep ALL
// `escapes`-flagged functions reachable. (Sound: a function whose
// address is never taken can never be the target of an indirect call.)
//
// minOptLevel = 1. Targets both backends — no codegen knowledge is
// needed past the call-graph walk.
@interface XTIROptDeadFunctionElim : NSObject <XTIROptPass>
// Library build mode: keep every function (the module's public API is reachable
// from outside, even though nothing in this unit calls it). Set by xtcg-<arch>
// when --emit-lib is passed.
+ (void)setKeepAllFunctions:(BOOL)keep;
@end

NS_ASSUME_NONNULL_END
